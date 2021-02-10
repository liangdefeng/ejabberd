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
	publish/7,
	get_attributes/0,
	get_attributes/1,
	disco_sm_features/5,
	sm_receive_packet/1,
	code_change/3]).

-define(SERVER, ?MODULE).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("translate.hrl").

-record(mod_aws_push_state, {host}).

-record(aws_push_type_token, {type_token, arn}).
-record(aws_push_pushkit_token, {pushkit_token, pushkit_arn}).
-record(aws_push_jid, {jid, token,arn, type,status,pushkit_token, pushkit_arn, msg_cnt}).

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
mod_opt_type(pushkit_platform_endpoint) ->
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
		{apn_push_type, "alert"},
		{pushkit_platform_endpoint, ""}
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
	ejabberd_mnesia:create(?MODULE, aws_push_pushkit_token,
		[{disc_copies, [node()]}, {attributes, record_info(fields, aws_push_pushkit_token)}]),

	application:set_env(erlcloud, aws_access_key_id, mod_aws_push_opt:aws_access_key_id(Opts)),
	application:set_env(erlcloud, aws_secret_access_key, mod_aws_push_opt:aws_secret_access_key(Opts)),
	application:set_env(erlcloud, aws_region, mod_aws_push_opt:aws_region(Opts)),
	application:set_env(erlcloud, fcm, mod_aws_push_opt:fcm_platform_endpoint(Opts)),
	application:set_env(erlcloud, apn, mod_aws_push_opt:apn_platform_endpoint(Opts)),
	application:set_env(erlcloud, pushkit, mod_aws_push_opt:pushkit_platform_endpoint(Opts)),
	application:set_env(erlcloud, apn_topic, mod_aws_push_opt:apn_topic(Opts)),
	application:set_env(erlcloud, apn_ttl, mod_aws_push_opt:apn_ttl(Opts)),
	application:set_env(erlcloud, apn_push_type, mod_aws_push_opt:apn_push_type(Opts)),
	application:set_env(erlcloud, apn_sandbox, mod_aws_push_opt:apn_sandbox(Opts)),

	{ok,_} = application:ensure_all_started(erlcloud),


	gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0, ?MODULE, process_iq),
	ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
	ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message, 70),
	ejabberd_hooks:add(sm_receive_packet, Host, ?MODULE, sm_receive_packet, 40),

	{ok, #mod_aws_push_state{host=Host}}.

handle_call(_Request, _From, State = #mod_aws_push_state{}) ->
	{reply, ok, State}.

handle_cast({offline_message_received,From, To, Packet}, State = #mod_aws_push_state{}) ->
	process_offline_message({From, To, Packet}),
	{noreply, State}.

handle_info(_Info, State = #mod_aws_push_state{}) ->
	{noreply, State}.

terminate(_Reason, _State = #mod_aws_push_state{host = Host}) ->
	application:stop(erlcloud),
	gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0),
	ejabberd_hooks:delete(sm_receive_packet, Host, ?MODULE, sm_receive_packet, 40),
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
offline_message({_Action, #message{from = From, to = To} = Packet} = _Acc) ->
	Proc = gen_mod:get_module_proc(To#jid.lserver, ?MODULE),
	gen_server:cast(Proc, {offline_message_received,From, To, Packet}),
	ok.

process_offline_message({From, To, #message{body = [#text{data = Data}] = _Body} = _Packet}) ->
	?INFO_MSG("start to process offline message to ~p~n",[To]),
	ToJID = jid:tolower(jid:remove_resource(To)),
	case string:slice(Data, 0, 19) of
		<<"aesgcm://w-4all.com">> ->
			ok;
		_ ->
			send_notification(From, ToJID, Data, offline, missed)
	end;
process_offline_message({From, To, #message{} = Pkt}) ->
	case xmpp:try_subtag(Pkt, #push_notification{}) of
		false ->
			ok;
		Record ->
			?DEBUG("Pkt:~p~n",[Pkt]),
			case Record of
				#push_notification{xdata = #xdata{fields = [#xdata_field{var = <<"type">>, values=[Type]},
					#xdata_field{var = <<"status">>, values = [StatusBinary]}]}} ->

					Status = binary_to_atom(string:lowercase(StatusBinary), unicode),
					case Status of
						start ->
							?DEBUG("Status is start, do nothing when user offline.~n",[]),
							ok;
						_ ->
							?DEBUG("Status is not start, send offfline notification.~n",[]),
							Type2 = binary_to_atom(string:lowercase(Type), unicode),
							ToJID = jid:tolower(jid:remove_resource(To)),
							send_notification(From, ToJID, <<>>, Type2, Status)
					end;
				_ ->
					ok
			end
	end;
process_offline_message(_) ->
	ok.

process_iq(#iq{from = From, lang = Lang, sub_els = [#push_enable{jid = _Jid,
		xdata = #xdata{fields = [
			#xdata_field{var = <<"type">>, values = [TypeParam]},
			#xdata_field{var = <<"token">>, values = [TokenParam]},
			#xdata_field{var = <<"pushkit_token">>, values = [PushKitTokenParam]}
		]}}]} = IQ) ->
	Params = [From,TypeParam,TokenParam, PushKitTokenParam],
	?INFO_MSG("User is registering its device.from:~p,type:~p,token:~p,pushkit_token:~p~n",Params),
	PushJID = jid:tolower(jid:remove_resource(From)),
	Type = binary_to_atom(string:lowercase(TypeParam), unicode),
	Token = string:lowercase(TokenParam),
	PushKitToken = string:lowercase(PushKitTokenParam),

	case mnesia:dirty_read({aws_push_jid, PushJID}) of
		[Item] when is_record(Item, aws_push_jid) ->
			#aws_push_jid{
				type = Type2,
				token = Token2,
				pushkit_token = PushKitToken2
			} = Item,
			case {Type2, Token2, PushKitToken2} of
				{Type, Token, PushKitToken} ->
					F = fun() -> update_msg_cnt(PushJID) end,
					transaction(IQ, F);
				_ ->
					case get_arns(Type, Token, PushKitToken) of
						{ok, {Arn3, PushKitArn3}} ->
							F = fun() -> update_push_jid(PushJID, Token, PushKitToken, Type, Arn3, PushKitArn3) end,
							transaction(IQ, F);
						{error, Reason} ->
							?ERROR_MSG("Error occurs.Reason:~p~n",[Reason]),
							xmpp:make_error(IQ, xmpp:err_unexpected_request(Reason, Lang))
					end
			end;
		_ ->
			case get_arns(Type, Token, PushKitToken) of
				{ok, {Arn3, PushKitArn3}} ->
					F = fun() -> insert_push_jid(PushJID, Token, PushKitToken, Type, Arn3, PushKitArn3) end,
					transaction(IQ, F);
				{error, Reason} ->
					?ERROR_MSG("Error occurs.Reason:~p~n",[Reason]),
					xmpp:make_error(IQ, xmpp:err_unexpected_request(Reason, Lang))
			end
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
	case PlatformAppArn of
		error ->
			{error, "Platform endpoint not found!"};
		_ ->
			try erlcloud_sns:create_platform_endpoint(PlatformAppArn,Token) of
				Result -> {ok, Result}
			catch
				_:Reason -> {error, Reason}
			end
	end.

transaction(#iq{lang = Lang} = IQ, F) ->
	case mnesia:transaction(F) of
		{atomic, _Res} ->
			xmpp:make_iq_result(IQ);
		{aborted, Reason} ->
			?ERROR_MSG("Error occurs.Reason:~p~n",[Reason]),
			xmpp:make_error(IQ, xmpp:err_bad_request(Reason, Lang))
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

get_attributes() ->
	[
		{"AWS.SNS.MOBILE.APNS.TOPIC", "com.w-4all.WorldUnification.voip"},
		{"AWS.SNS.MOBILE.APNS.PRIORITY", 10},
		{"AWS.SNS.MOBILE.APNS.TTL", 0},
		{"AWS.SNS.MOBILE.APNS.PUSH_TYPE", "voip"}
	].

get_arns(Type, Token, PushKitToken) ->
	case Type of
		fcm ->
			case get_type_token_arn(Type, Token) of
				{ok, Arn} ->
					{ok, {Arn, ""}};
				Error ->
					Error
			end;
		apn ->
			case get_type_token_arn(Type, Token) of
				{ok, Arn} ->
					case get_pushkit_token_arn(PushKitToken) of
						{ok, PushKitArn} ->
							{ok, {Arn, PushKitArn}};
						Error ->
							Error
					end;
				Error ->
					Error
			end;
		_ ->
			{error, "Unsupport type!"}
	end.

get_type_token_arn(Type, Token) ->
	PlatformAppArn = application:get_env(erlcloud, Type, error),
	case mnesia:dirty_read({aws_push_type_token, {Type, Token}}) of
		[Item] ->
			#aws_push_type_token{arn = Arn} = Item,
			{ok, Arn};
		_ ->
			case create_platform_endpoint(PlatformAppArn, Token) of
				{ok, Arn} ->
					insert_type_token(Type, Token, Arn);
				Error ->
					Error
			end
	end.

get_pushkit_token_arn(PushKitToken) ->
	PlatformAppArn = application:get_env(erlcloud, pushkit, error),
	case mnesia:dirty_read({aws_push_pushkit_token, PushKitToken}) of
		[Item] ->
			#aws_push_pushkit_token{pushkit_arn = Arn} = Item,
			{ok, Arn};
		_ ->
			case create_platform_endpoint(PlatformAppArn,PushKitToken) of
				{ok, Arn} ->
					insert_pushkit_token(PushKitToken, Arn);
				Error ->
					Error
			end
	end.

insert_type_token(Type, Token, Arn) ->
	F = fun() ->
		mnesia:write(#aws_push_type_token{
			type_token = {Type, Token},
			arn = Arn
		})
	    end,
	case mnesia:transaction(F) of
		{atomic, _Res} ->
			{ok,Arn};
		{aborted, Reason} ->
			{error, Reason}
	end.

insert_pushkit_token(Token, Arn) ->
	F = fun() ->
		mnesia:write(#aws_push_pushkit_token{
			pushkit_token = Token,
			pushkit_arn = Arn
		})
	    end,
	case mnesia:transaction(F) of
		{atomic, _Res} ->
			{ok,Arn};
		{aborted, Reason} ->
			{error, Reason}
	end.

update_msg_cnt(PushJID) ->
	case mnesia:wread({aws_push_jid, PushJID}) of
		[Item] when is_record(Item, aws_push_jid) ->
			mnesia:write(Item#aws_push_jid{
				msg_cnt = 0
			});
		_ ->
			ok
	end.

update_push_jid(PushJID, Token, PushKitToken, Type, Arn, PushKitArn) ->
	case mnesia:wread({aws_push_jid, PushJID}) of
		[Item] when is_record(Item, aws_push_jid) ->
			mnesia:write(Item#aws_push_jid{
				type = Type,
				token = Token,
				pushkit_token = PushKitToken,
				msg_cnt = 0,
				arn = Arn,
				pushkit_arn = PushKitArn
			});
		_ ->
			ok
	end.

insert_push_jid(PushJID, Token, PushKitToken, Type, Arn, PushKitArn) ->
	mnesia:write(#aws_push_jid{
		jid = PushJID,
		status = true,
		pushkit_token = PushKitToken,
		msg_cnt = 0,
		token = Token,
		type = Type,
		arn = Arn,
		pushkit_arn = PushKitArn
	}).

-spec sm_receive_packet(stanza()) -> stanza().
sm_receive_packet(#message{from = From, to = To} = Pkt) ->
	case xmpp:try_subtag(Pkt, #push_notification{}) of
		false ->
			ok;
		Record ->
			?DEBUG("Pkt:~p~n",[Pkt]),
			case Record of
				#push_notification{xdata = #xdata{fields = [#xdata_field{var = <<"type">>, values=[Type]},
					#xdata_field{var = <<"status">>, values = [<<"start">>]}]}} ->

					?DEBUG("status is start, send pushkit notification.~n",[]),
					Type2 = binary_to_atom(string:lowercase(Type), unicode),
					ToJID = jid:tolower(jid:remove_resource(To)),
					send_notification(From, ToJID, <<>>, Type2, start);
				_ ->

					?DEBUG("Status is start, do nothing when user online.~n",[]),
					ok
			end
	end,
	Pkt;
sm_receive_packet(Acc) ->
	Acc.

send_notification(FromJid, ToJid, Data, Type2, CallTypeStatus) ->
	case mnesia:dirty_read(aws_push_jid, ToJid) of
		[Item] when is_record(Item, aws_push_jid) ->
			#aws_push_jid{
				type = Type,
				status = Status,
				pushkit_arn = PushKitArn,
				arn=Arn} = Item,
			case Status of
				true ->
					case publish(PushKitArn, Arn, Type, FromJid, Data, Type2, CallTypeStatus) of
						{ok, _} ->
							?INFO_MSG("Notification sent.Jid:~p~n", [ToJid]),
							ok;
						{error, Reason} ->
							?ERROR_MSG(
								"Error occurs when sending message to arn. Reason:~p,Arn:~p,PushKitArn~p~n",
								[Reason, Arn, PushKitArn]),
							ok
					end;
				_ ->
					?INFO_MSG("Use has disabled notification.Jid:~p~n", [ToJid]),
					ok
			end;
		_ ->
			?INFO_MSG("Use has not registered notification.Jid:~p~n", [ToJid]),
			ok
	end.

publish(PushKitArn, Arn, Type, FromJid, Data, Type2, CallTypeStatus) ->

	#jid{user = FromUser} = FromJid,
	case Type of
		fcm ->
			Message = "You have a message from " ++ binary_to_list(FromUser),
			try erlcloud_sns:publ(target, Arn,
				Message, undefined,
				get_attributes(Type), erlcloud_aws:default_config()) of
				Result -> {ok, Result}
			catch
				_:Reason -> {error, Reason}
			end;
		_ ->
			{Arn2, Msg} =
				case Type2 of
					location ->
						Message = "{\"APNS\":" ++
							"\"{\\\"aps\\\":{\\\"badge\\\":7," ++
							"\\\"soundId\\\":\\\"1007\\\"," ++
							"\\\"content-available\\\":1," ++
							"\\\"alert\\\":{\\\"title\\\":\\\""
							++ "You've received a location message from "
							++ binary_to_list(FromUser)
							++ "\\\"}}}\"}",
						{Arn, Message};
					photo ->
						Message = "{\"APNS\":" ++
							"\"{\\\"aps\\\":{\\\"badge\\\":6," ++
							"\\\"soundId\\\":\\\"1018\\\"," ++
							"\\\"content-available\\\":1," ++
							"\\\"alert\\\":{\\\"title\\\":\\\""
							++ "You've received a photo message from "
							++ binary_to_list(FromUser)
							++ "\\\"}}}\"}",
						{Arn, Message};
					files ->
						Message = "{\"APNS\":" ++
							"\"{\\\"aps\\\":{\\\"badge\\\":3," ++
							"\\\"soundId\\\":\\\"1018\\\"," ++
							"\\\"content-available\\\":1," ++
							"\\\"alert\\\":{\\\"title\\\":\\\""
							++ "You've received a file message from "
							++ binary_to_list(FromUser)
							++ "\\\"}}}\"}",
						{Arn, Message};
					voice ->
						Message =
							case CallTypeStatus of
								start ->
									"{\"APNS_VOIP\":" ++
										"\"{\\\"aps\\\":{\\\"badge\\\":4," ++
										"\\\"soundId\\\":\\\"1150\\\"," ++
										"\\\"content-available\\\":1," ++
										"\\\"alert\\\":{\\\"title\\\":\\\""
										++ "You've received a voice call from "
										++ binary_to_list(FromUser)
										++ "\\\"}}}\"}";
								missed ->
									"{\"APNS\":" ++
										"\"{\\\"aps\\\":{\\\"badge\\\":4," ++
										"\\\"soundId\\\":\\\"1150\\\"," ++
										"\\\"content-available\\\":1," ++
										"\\\"alert\\\":{\\\"title\\\":\\\""
										++ "You've receive a voice call from "
										++ binary_to_list(FromUser)
										++ "\\\"}}}\"}";
								_ ->
									"{\"APNS\":" ++
										"\"{\\\"aps\\\":{\\\"badge\\\":1," ++
										"\\\"soundId\\\":\\\"1010\\\"," ++
										"\\\"content-available\\\":1," ++
										"\\\"alert\\\":{\\\"title\\\":\\\""
										++ "You've received a voice message from "
										++ binary_to_list(FromUser)
										++ "\\\"}}}\"}"
							end,
						{Arn, Message};
					video ->
						Message =
							case CallTypeStatus of
								start ->
									"{\"APNS_VOIP\":" ++
										"\"{\\\"aps\\\":{\\\"badge\\\":5," ++
										"\\\"soundId\\\":\\\"1152\\\"," ++
										"\\\"content-available\\\":1," ++
										"\\\"alert\\\":{\\\"title\\\":\\\""
										++ "You've received a video call from "
										++ binary_to_list(FromUser)
										++ "\\\"}}}\"}";
								missed ->
									"{\"APNS\":" ++
										"\"{\\\"aps\\\":{\\\"badge\\\":5," ++
										"\\\"soundId\\\":\\\"1152\\\"," ++
										"\\\"content-available\\\":1," ++
										"\\\"alert\\\":{\\\"title\\\":\\\""
										++ "You've received a video call from "
										++ binary_to_list(FromUser)
										++ "\\\"}}}\"}";
								_ ->
									"{\"APNS\":" ++
										"\"{\\\"aps\\\":{\\\"badge\\\":2," ++
										"\\\"soundId\\\":\\\"1262\\\"," ++
										"\\\"content-available\\\":1," ++
										"\\\"alert\\\":{\\\"title\\\":\\\""
										++ "You've received a video message from "
										++ binary_to_list(FromUser)
										++ "\\\"}}}\"}"
								end,
						{Arn, Message};
					_ ->
						[Data2 | _Rest] = string:split(Data, "\n"),
						Len = string:length(Data2),
						Data3 = if Len > 15 -> string:slice(binary_to_list(Data2),0,15) ++ "...";
											true -> binary_to_list(Data2)
										end,
						Message = "{\"APNS\":" ++
							"\"{\\\"aps\\\":{\\\"badge\\\":10," ++
							"\\\"soundId\\\":\\\"1002\\\"," ++
							"\\\"content-available\\\":1," ++
							"\\\"alert\\\":{" ++
							"\\\"title\\\":\\\"" ++
							"You've received a text message from "
							++ binary_to_list(FromUser)
							++ "\\\",\\\"body\\\":\\\""
							++ Data3
							++ "\\\"}}}\"}",
						?DEBUG("Data:~p~n",[Message]),
						{Arn, Message}
				end,
			case CallTypeStatus of
				start ->
					try erlcloud_sns:publish(target, PushKitArn,
						Msg, undefined, get_attributes(), erlcloud_aws:default_config()) of
						Result ->
							?INFO_MSG("PushKit published.From:~p, MessageId:~p~n", [jid:to_string(FromUser), Result]),
							{ok, Result}
					catch
						_:Reason -> {error, Reason}
					end;
				_ ->
					try erlcloud_sns:publish(target, Arn2,
						list_to_binary(Msg), undefined,
						get_attributes(Type), erlcloud_aws:default_config()) of
						Result ->
							?INFO_MSG("Notification published.From:~p, MessageId:~p~n", [jid:to_string(FromUser), Result]),
							{ok, Result}
					catch
						_:Reason -> {error, Reason}
					end
			end
	end.
