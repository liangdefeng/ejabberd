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

-record(aws_notification, {jid, arn, arn_status, token, status, type}).

%%%===================================================================
%%% Spawning and gen_mod implementation
%%%===================================================================
start(Host, Opts) ->
	ejabberd_mnesia:create(?MODULE, aws_notification,
		[{disc_copies, [node()]}, {attributes, record_info(fields, aws_notification)}]),

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
	?INFO_MSG("~p offline_message started.~n",[?MODULE]),
	case mnesia:dirty_read({aws_notification, To}) of
		[Item] when is_record(Item, aws_notification) ->
			#aws_notification{arn = Arn, status = Status} = Item,
			case Status of
				true ->
					case erlcloud_sns:get_endpoint_attributes(Arn) of
						[_, {attributes,[{enabled,"true"},_]}] ->
							?INFO_MSG("publish message to aws.~n", []),
							erlcloud_sns:publish(
								target,
								Arn,
								"You have received a message.",
								"Subject",
								erlcloud_aws:default_config()
							);
						_ ->
							?INFO_MSG("end point is disabled.~n", []),
							ok
					end;
				_ ->
					?INFO_MSG("Use has disabled notification.~n", []),
					ok
			end;
		_ ->
			ok
	end.

process_iq(#iq{from = _From,
	to = _To,
	lang = _Lang,
	sub_els = [#push_enable{
		jid = PushJID,
		node = _Node,
		xdata = XData}]} = IQ) ->


	?INFO_MSG("~p process_iq started.IQ:~n",[?MODULE]),

	#xdata{fields = [
		#xdata_field{var = <<"type">>, values = [Type]},
		#xdata_field{var = <<"token">>, values = [Token]}
	]} = XData,

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

	case get_platform_endpoint_arn(PlatformAppArn,Token) of
		{ok, PlatformEndPointArn} ->
			F = fun () ->
					case mnesia:wread({aws_notification, PushJID}) of
						[] ->
							mnesia:write(#aws_notification{
								jid = PushJID,
								arn = PlatformEndPointArn,
								token = Token,
								status = true,
								type = Type
							});
						[Item] when is_record(Item, aws_notification) ->
							mnesia:write(Item#aws_notification{
								arn = PlatformEndPointArn,
								token = Token,
								status = true,
								type = Type
							});
						_ ->
							false
					end
			    end,
			case mnesia:transaction(F) of
				{atomic, _Res} ->
					?INFO_MSG("write table aws_notification success!~n",[]),
					xmpp:make_iq_result(IQ);
				{aborted, Reason} ->
					?ERROR_MSG("timeout check error: ~p~n", [Reason]),
					xmpp:make_error(IQ, xmpp:err_not_allowed())
			end;
		_ ->
			xmpp:make_error(IQ, xmpp:err_not_allowed())
	end;
process_iq(#iq{from = _From,
	to = _To,
	lang = _Lang,
	sub_els = [#push_disable{jid = PushJID,
		node = _Node}]} = IQ) ->
	?INFO_MSG("~p process_iq started.IQ=~p~n",[?MODULE, IQ]),

	F = fun () ->
			case mnesia:wread({aws_notification, PushJID}) of
				[Item] when is_record(Item, aws_notification) ->
					mnesia:write(Item#aws_notification{
						status = false
					});
				_ ->
					ok
			end
		end,
	case mnesia:transaction(F) of
		{atomic, _Res} ->
			?INFO_MSG("Update status = false in table aws_notification success!~n",[]),
			xmpp:make_iq_result(IQ);
		{aborted, Reason} ->
			?ERROR_MSG("timeout check error: ~p~n", [Reason]),
			xmpp:make_error(IQ, xmpp:err_not_allowed())
	end;
process_iq(IQ) ->
	?INFO_MSG("~p process_iq started.~n",[?MODULE]),
	xmpp:make_error(IQ, xmpp:err_not_allowed()).

get_platform_endpoint_arn(PlatformAppArn,Token) ->
	try erlcloud_sns:create_platform_endpoint(PlatformAppArn,Token) of
		Result -> {ok, Result}
	catch
	    _:Reason -> {error, Reason}
	end.