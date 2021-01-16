%%%-------------------------------------------------------------------
%%% @author Peter Liang
%%% @copyright (C) 2020, Peter Liang
%%% @doc
%%% The purpose of the module is to allow user to register hit/her device
%%% to fcm or apns through AWS SNS mobile notification.
%%%
%%% When offline message is sent to user, user's device will receive notification.
%%%
%%% User can enable or disable notification.
%%% @end
%%%-------------------------------------------------------------------
-module(mod_aws_push).

-author('Peter Leung').

-behaviour(gen_mod).
-behaviour(gen_server).

-export([start/2, stop/1]).
-export([mod_doc/0, mod_options/1, depends/2, reload/3, mod_opt_type/1]).
-export([process_iq/1, offline_message/1, process_offline_message/1]).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
	publish/3,
	make_message/2,
	get_attributes/1,
	disco_sm_features/5,
	code_change/3]).

-define(SERVER, ?MODULE).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("translate.hrl").

-record(mod_aws_push_state, {host}).

-record(aws_push_type_token, {type_token, arn}).
-record(aws_push_jid, {jid, token, type, status, arn}).

%%%===================================================================
%%% Spawning and gen_mod implementation
%%%===================================================================
start(Host, Opts) ->
	gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
	gen_mod:stop_child(?MODULE, Host).

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
	econf:string();
mod_opt_type(apn_topic) ->
	econf:string();
mod_opt_type(apn_ttl) ->
	econf:int();
mod_opt_type(apn_sandbox) ->
	econf:bool();
mod_opt_type(apn_push_type) ->
	econf:string().

mod_options(_Host) ->
	[{aws_access_key_id,""},
		{aws_secret_access_key, ""},
		{aws_region, "us-west-1"},
		{fcm_platform_endpoint, ""},
		{apn_platform_endpoint, ""},
		{apn_topic, ""},
		{apn_ttl, 5},
		{apn_sandbox, true},
		{apn_push_type, "alert"}
	].

mod_doc() ->
	#{}.

depends(_Host, _Opts) ->
	[].

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link(Host, Opts) ->
	Proc = gen_mod:get_module_proc(Host, ?MODULE),
	gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init([Host, Opts]) ->
	?INFO_MSG("start ~p~n",[?MODULE]),

	ejabberd_mnesia:create(?MODULE, aws_push_type_token,
		[{disc_copies, [node()]}, {attributes, record_info(fields, aws_push_type_token)}]),
	ejabberd_mnesia:create(?MODULE, aws_push_jid,
		[{disc_copies, [node()]}, {attributes, record_info(fields, aws_push_jid)}]),

	application:set_env(erlcloud, aws_access_key_id, mod_aws_push_opt:aws_access_key_id(Opts)),
	application:set_env(erlcloud, aws_secret_access_key, mod_aws_push_opt:aws_secret_access_key(Opts)),
	application:set_env(erlcloud, aws_region, mod_aws_push_opt:aws_region(Opts)),
	application:set_env(erlcloud, fcm, mod_aws_push_opt:fcm_platform_endpoint(Opts)),
	application:set_env(erlcloud, apn, mod_aws_push_opt:apn_platform_endpoint(Opts)),
	application:set_env(erlcloud, apn_topic, mod_aws_push_opt:apn_topic(Opts)),
	application:set_env(erlcloud, apn_ttl, mod_aws_push_opt:apn_ttl(Opts)),
	application:set_env(erlcloud, apn_push_type, mod_aws_push_opt:apn_push_type(Opts)),
	application:set_env(erlcloud, apn_sandbox, mod_aws_push_opt:apn_sandbox(Opts)),

	{ok,_} = application:ensure_all_started(erlcloud),

	gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0, ?MODULE, process_iq),
	ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
	ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message, 70),

	{ok, #mod_aws_push_state{host=Host}}.

handle_call(_Request, _From, State = #mod_aws_push_state{}) ->
	{reply, ok, State}.

handle_cast({offline_message_received,To, Packet}, State = #mod_aws_push_state{}) ->
	process_offline_message({To, Packet}),
	{noreply, State}.

handle_info(_Info, State = #mod_aws_push_state{}) ->
	{noreply, State}.

terminate(_Reason, _State = #mod_aws_push_state{host = Host}) ->
	application:stop(erlcloud),
	gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0),
	ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
	ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message, 70).

code_change(_OldVsn, State = #mod_aws_push_state{}, _Extra) ->
	{ok, State}.

disco_sm_features(empty, From, To, Node, Lang) ->
	disco_sm_features({result, []}, From, To, Node, Lang);
disco_sm_features({result, OtherFeatures},
	#jid{luser = U, lserver = S},
	#jid{luser = U, lserver = S}, <<"">>, _Lang) ->
	{result, [?NS_PUSH_0 | OtherFeatures]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
	Acc.
%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec offline_message({any(), message()}) -> {any(), message()}.
offline_message({_Action, #message{to = To} = Packet} = _Acc) ->
	?INFO_MSG("User has received an offline message. Jid:~p~n",[To]),
	Proc = gen_mod:get_module_proc(To#jid.lserver, ?MODULE),
	gen_server:cast(Proc, {offline_message_received,To, Packet}),
	ok.

process_offline_message({To, #message{body = [#text{data = Data}] = _Body} = _Packet}) ->
	?INFO_MSG("start to process offline message to ~p~n",[To]),
	case mnesia:dirty_read(aws_push_jid, To) of
		[Item] when is_record(Item, aws_push_jid) ->
			#aws_push_jid{type = Type, status = Status, arn=Arn} = Item,
			case Status of
				true ->
					Type2 = binary_to_atom(string:lowercase(Type), unicode),
					Message = make_message(Type2, Data),
					Attributes = get_attributes(Type2),
					case publish(Arn, Message, Attributes) of
						{ok, _} ->
							?INFO_MSG("Notification sent.Jid:~p~n", [To]),
							ok;
						{error, Reason} ->
							?ERROR_MSG(
								"Error occurs when sending message to arn. Reason:~p,Arn:~p~n",
								[Reason, Arn]),
							ok
					end;
				_ ->
					?INFO_MSG("Use has disabled notification.Jid:~p~n", [To]),
					ok
			end;
		_ ->
			?INFO_MSG("Use has not registered notification.Jid:~p~n", [To]),
			ok
	end;
process_offline_message({_To, _Packet}) ->
	?INFO_MSG("Do nothing!", []),
	ok.

process_iq(#iq{from = From, lang = Lang, sub_els = [#push_enable{jid = _Jid,
		xdata = #xdata{fields = [
			#xdata_field{var = <<"type">>, values = [TypeParam]},
			#xdata_field{var = <<"token">>, values = [TokenParam]}
		]}}]} = IQ) ->
	PushJID = jid:tolower(jid:remove_resource(From)),
	Type = binary_to_atom(string:lowercase(TypeParam), unicode),
	Token = string:lowercase(TokenParam),
	?INFO_MSG("User is registering its device.Jid:~p,Type:~p,Token:~p~n",[PushJID,Type,Token]),

	% Get Platform Arn
	case application:get_env(erlcloud, Type) of
		{ok, PlatformAppArn} ->
			case mnesia:dirty_read({aws_push_type_token, {Type, Token}}) of
				[Item] when is_record(Item, aws_push_type_token) ->
					#aws_push_type_token{arn = Arn} = Item,
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
									% Associate the PushJid with the exiting token, type and arn.
									F = fun() -> update_push_jid(PushJID, Token, Type, Arn) end,
									transaction(IQ, F)
							end;
						_ ->
							F = fun () ->
								mnesia:write(Item#aws_push_jid{
									jid = PushJID,
									type = Type,
									status = true,
									token = Token,
									arn = Arn
								})
							    end,
							transaction(IQ, F)
					end;
				_ ->
					case create_platform_endpoint(PlatformAppArn,Token) of
						{ok, Arn} ->
							% insert aws_push_jid and aws_push_type_token.
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
		_ ->
			xmpp:make_error(IQ, xmpp:err_not_allowed())
	end;
process_iq(#iq{from = From, lang = _Lang, sub_els = [#push_enable{jid = _Jid}]} = IQ) ->
	PushJID = jid:tolower(jid:remove_resource(From)),
	?INFO_MSG("User has enabled its notification.Jid:~p~n",[PushJID]),
	F = fun () ->
			case mnesia:wread({aws_push_jid, PushJID}) of
				[Item] when is_record(Item, aws_push_jid) ->
					mnesia:write(Item#aws_push_jid{
						status = true
					});
				_ ->
					ok
			end
	    end,
	transaction(IQ, F);
process_iq(#iq{from = From, sub_els = [#push_disable{jid = _Jid}]} = IQ) ->
	PushJID = jid:tolower(jid:remove_resource(From)),
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
process_iq(#iq{} = IQ) ->
	xmpp:make_error(IQ, xmpp:err_not_allowed()).

create_platform_endpoint(PlatformAppArn,Token) ->
	try erlcloud_sns:create_platform_endpoint(PlatformAppArn,Token) of
		Result -> {ok, Result}
	catch
	    _:Reason -> {error, Reason}
	end.

publish(Arn, Message, Attributes) ->
	try erlcloud_sns:publish(target, Arn, Message, undefined, Attributes, erlcloud_aws:default_config()) of
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

update_push_jid(PushJID, Token, Type, Arn) ->

	case mnesia:wread({aws_push_jid, PushJID}) of
		[Item] when is_record(Item, aws_push_jid) ->
			mnesia:write(Item#aws_push_jid{
				type = Type,
				token = Token,
				arn = Arn
			});
		_ ->
			ok
	end.

insert_all_tables(PushJID, Token, Type, Arn) ->
	mnesia:write(#aws_push_jid{
		jid = PushJID,
		status = true,
		token = Token,
		type = Type,
		arn = Arn
	}),
	mnesia:write(#aws_push_type_token{
		type_token = {Type, Token},
		arn = Arn
	}).

make_message(Type,Data) ->
	case Type of
		fcm ->
			"{'GCM':\"{\"notification\":{\"body\": \"" ++ binary_to_list(Data)
				++ "\",\"sound\":\"default\"}}\"}";
		_ ->
			FirstElement = case application:get_env(erlcloud, apn_sandbox) of
				               {ok,true} -> 'APNS_SANDBOX';
				               _ -> 'APNS'
			               end,
			"{'" ++ atom_to_list(FirstElement) ++
				"':\"{\"aps\":{\"badge\": 2,\"sound\":\"default\",\"alert\":{\"body\": \""
				++ binary_to_list(Data) ++ "\"}}}\"}"
	end.


get_attributes(Type) ->
	case Type of
		fcm ->
			[];
		_ ->
			{ok, Ttl} = application:get_env(erlcloud, apn_ttl),
			{ok, Topic} = application:get_env(erlcloud, apn_topic),
			{ok, PushType} = application:get_env(erlcloud, apn_push_type),
			ApnTtl = case application:get_env(erlcloud, apn_sandbox) of
				         {ok, true} ->
					         [{"AWS.SNS.MOBILE.APNS_SANDBOX.TTL", Ttl}];
				         _ ->
					         [{"AWS.SNS.MOBILE.APNS.TTL", Ttl}]
			         end,
			[{"AWS.SNS.MOBILE.APNS.TOPIC", Topic},
				{"AWS.SNS.MOBILE.APNS.PRIORITY", 10},
				{"AWS.SNS.MOBILE.APNS.PUSH_TYPE", PushType}
			] ++ ApnTtl
	end.
