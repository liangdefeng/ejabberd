%%%-------------------------------------------------------------------
%%% @author Peter Leung
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(mod_aws_push).

-author('Peter Leung').

-behaviour(gen_mod).

-export([start/2, stop/1]).
-export([mod_doc/0, mod_options/1, depends/2, reload/3, mod_opt_type/1]).
-export([process_iq/1, offline_message/1]).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("translate.hrl").

-record(aws_push_jid_type_token, {jid_type_token, arn}).
-record(aws_push_jid_seq, {jid_seq, token, type}).
-record(aws_push_jid, {jid, seq, token, type, status, arn}).

%%%===================================================================
%%% Spawning and gen_mod implementation
%%%===================================================================
start(Host, Opts) ->
	ejabberd_mnesia:create(?MODULE, aws_push_jid_type_token,
		[{disc_copies, [node()]}, {attributes, record_info(fields, aws_push_jid_type_token)}]),

	ejabberd_mnesia:create(?MODULE, aws_push_jid_seq,
		[{disc_copies, [node()]}, {attributes, record_info(fields, aws_push_jid_seq)}]),

	ejabberd_mnesia:create(?MODULE, aws_push_jid,
		[{disc_copies, [node()]}, {attributes, record_info(fields, aws_push_jid)}]),

	gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0, ?MODULE, process_iq),
	ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message, 70),

	application:set_env(erlcloud, aws_access_key_id, mod_aws_push_opt:aws_access_key_id(Opts)),
	application:set_env(erlcloud, aws_secret_access_key, mod_aws_push_opt:aws_secret_access_key(Opts)),
	application:set_env(erlcloud, aws_region, mod_aws_push_opt:aws_region(Opts)),
	application:set_env(erlcloud, fcm, mod_aws_push_opt:fcm_platform_endpoint(Opts)),
	application:set_env(erlcloud, apn, mod_aws_push_opt:apn_platform_endpoint(Opts)),

	{ok,_} = application:ensure_all_started(erlcloud),
	?INFO_MSG("~p start started.~n",[?MODULE]),
	ok.

stop(Host) ->
	gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0),
	ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message, 70),
	application:stop(erlcloud).

reload(_Host, _NewOpts, _OldOpts) ->
	ok.

mod_opt_type(aws_access_key_id) ->
	econf:string();
mod_opt_type(aws_secret_access_key) ->
	econf:string();
mod_opt_type(aws_region) ->
	econf:string();
mod_opt_type(fcm_platform_endpoint) ->
	econf:string();
mod_opt_type(apn_platform_endpoint) ->
	econf:string().

mod_options(_Host) ->
	[{aws_access_key_id,""},
		{aws_secret_access_key, ""},
		{aws_region, ""},
		{fcm_platform_endpoint, ""},
		{apn_platform_endpoint, ""}
	].

mod_doc() ->
	#{}.

depends(_Host, _Opts) ->
	[].

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec offline_message({any(), message()}) -> {any(), message()}.
offline_message({_Action, #message{to = To} = _Packet} = _Acc) ->
	?INFO_MSG("User has received an offline message. Jid:~p~n",[To]),
	case mnesia:dirty_read(aws_push_jid, To) of
		[Item] when is_record(Item, aws_push_jid) ->
			#aws_push_jid{status = Status, arn=Arn} = Item,
			case Status of
				true ->
					Message = <<"Test Message">>,
					Subject = "Subject",
					case publish(Arn, Message, Subject) of
						{ok, _} ->
							?INFO_MSG("Notification sent.~n", []),
							ok;
						{error, Reason} ->
							?ERROR_MSG(
								"Error occurs when sending message to arn. Reason:~p,Arn:~p~n",
								[Reason, Arn]),
							ok
					end;
				_ ->
					?INFO_MSG("Use has disabled notification.~n", []),
					ok
			end;
		_ ->
			?INFO_MSG("Use has not registered notification.~n", []),
			ok
	end.

process_iq(#iq{from = _From,
	to = _To,
	lang = Lang,
	sub_els = [#push_enable{
		jid = PushJID,
		node = _Node,
		xdata = #xdata{fields = [
			#xdata_field{var = <<"type">>, values = [Type]},
			#xdata_field{var = <<"token">>, values = [Token]}
		]}}]} = IQ) ->

	?INFO_MSG("User is registering its device.Jid:~p,Type:~p,Token:~p~n",[PushJID,Type,Token]),

	% Get Platform Arn
	PlatformAppArn =
		case Type of
			<<"apn">> ->
				{ok, ApnPlatformEndpoint} = application:get_env(erlcloud, apn),
				ApnPlatformEndpoint;
			<<"fcm">> ->
				{ok, FcmPlatformEndpoint} = application:get_env(erlcloud, fcm),
				FcmPlatformEndpoint;
			_ ->
				xmpp:make_error(IQ, xmpp:err_not_allowed())
		end,

	case mnesia:dirty_read({aws_push_jid_type_token, {PushJID, Type, Token}}) of
		[Item] when is_record(Item, aws_push_jid_type_token) ->
			#aws_push_jid_type_token{arn = Arn} = Item,
			case mnesia:dirty_read({aws_push_jid, PushJID}) of
				[Item2] when is_record(Item2, aws_push_jid) ->
					#aws_push_jid{type = Type2, token = Token2} = Item2,
					case {Type2, Token2} of
						{Type, Token} ->
							% when user use the same device.
							xmpp:make_iq_result(IQ);
						_ ->
							% this will happen when user switch device
							% insert aws_push_jid_seq table and update aws_push_jid.
							F = fun() -> insert_part_tables(PushJID, Token, Type, Arn) end,
							transaction(IQ, F)
					end;
				_ ->
					% if the transaction works well, this is the case it should never happens.
					?ERROR_MSG(
						"The record has integrity issue. JId:~p, Type:~p, Token:~p~n",
						[PushJID, Type, Token]),
					Txt = ?T("System error occurs."),
					xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
			end;
		_ ->
			case get_platform_endpoint_arn(PlatformAppArn,Token) of
				{ok, Arn} ->
					% insert aws_push_jid, aws_push_jid_seq and aws_push_jid_type_token.
					F = fun() -> insert_all_tables(PushJID, Token, Type, Arn) end,
					transaction(IQ, F);
				{error, Reason} ->
					?ERROR_MSG(
						"Can't create a new platform endpoint arn. Reason:~p, JId:~p, Type:~p, Token:~p~n",
						[Reason, PushJID, Type, Token]),
					Txt = ?T(Reason),
					xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
			end
	end;
process_iq(#iq{from = _From,
	to = _To,
	lang = _Lang,
	sub_els = [#push_disable{jid = PushJID,
		node = _Node}]} = IQ) ->
	?INFO_MSG("User has disabled its notification.Jid:~p~n",[PushJID]),
	F = fun () ->
		case mnesia:wread({aws_push_jid, PushJID}) of
			[Item] when is_record(Item, aws_push_jid) ->
				mnesia:write(Item#aws_push_jid{
					status = false
				});
			_ ->
				ok
		end
	end,
	transaction(IQ, F);
process_iq(#iq{lang = _Lang} = IQ) ->
	?INFO_MSG("~p process_iq started.~n",[?MODULE]),
	xmpp:make_error(IQ, xmpp:err_not_allowed()).

get_platform_endpoint_arn(PlatformAppArn,Token) ->
	try erlcloud_sns:create_platform_endpoint(PlatformAppArn,Token) of
		Result -> {ok, Result}
	catch
	    _:Reason -> {error, Reason}
	end.

publish(Arn, Message, Subject) ->
	try erlcloud_sns:publish(target,Arn,Message, Subject,erlcloud_aws:default_config()) of
		Result -> {ok, Result}
	catch
		_:Reason -> {error, Reason}
	end.

transaction(#iq{lang = Lang} = IQ, F) ->
	case mnesia:transaction(F) of
		{atomic, _Res} ->
			xmpp:make_iq_result(IQ);
		{aborted, Reason} ->
			?ERROR_MSG("Database failure. Reason:~p~n", [Reason]),
			Txt = ?T("Database failure."),
			xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
	end.

insert_part_tables(PushJID, Token, Type, Arn) ->

	Seq = {erlang:timestamp(), node()},
	case mnesia:wread({aws_push_jid, PushJID}) of
		[Item] when is_record(Item, aws_push_jid) ->
			mnesia:write(Item#aws_push_jid{
				seq = Seq,
				type = Type,
				token = Token,
				arn = Arn
			});
		_ ->
			ok
	end,
	mnesia:write(#aws_push_jid_seq{
		jid_seq = {PushJID, Seq},
		token = Token,
		type = Type
	}).

insert_all_tables(PushJID, Token, Type, Arn) ->
	Seq = {erlang:timestamp(), node()},
	mnesia:write(#aws_push_jid{
		jid = PushJID,
		seq = Seq,
		status = true,
		token = Token,
		type = Type,
		arn = Arn
	}),
	mnesia:write(#aws_push_jid_seq{
		jid_seq = {PushJID, Seq},
		token = Token,
		type = Type
	}),
	mnesia:write(#aws_push_jid_type_token{
		jid_type_token = {PushJID, Type, Token},
		arn = Arn
	}).
