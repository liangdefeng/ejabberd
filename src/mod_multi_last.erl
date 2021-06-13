%%%----------------------------------------------------------------------
%%% File    : mod_multi_last.erl
%%% Author  : Peter Liang
%%%----------------------------------------------------------------------

-module(mod_multi_last).

-author('defeng.liang.cn@gmail.com').

-behaviour(gen_mod).

-export([start/2, stop/1,
  process_iq/1,
  get_last/3,
  depends/2,
  mod_options/1,
  mod_doc/0
]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("mod_privacy.hrl").
-include("translate.hrl").

-define(LAST_CACHE, last_activity_cache).

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
          ?NS_MULTI_LAST, ?MODULE, process_iq).
stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host,
          ?NS_MULTI_LAST).

-spec process_iq(iq()) -> iq().
process_iq(#iq{type = set, lang = Lang} = IQ) ->
	Txt = ?T("Value 'set' of 'type' attribute is not allowed"),
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_iq(#iq{type = get, from = From, lang = Lang,
  sub_els = [#multi_last_query{items = Items}]} = IQ) ->
  RetItems = lists:filtermap(
    fun(Item) ->
      #multi_last_item{jid = ToJid} = Item,
      case get_last(From, ToJid, Lang) of
        {ok, TimeStamp, Status} ->
          {true, #multi_last_item{jid = ToJid,
                                  seconds = TimeStamp,
                                  text = Status}};
        {error, Code, Reason, _Txt} ->
          {true, #multi_last_item{jid = ToJid,
                                  errcode = Code,
                                  text = atom_to_binary(Reason, unicode)}};
        _ ->
          false
      end
    end,
    Items),
  xmpp:make_iq_result(IQ, #multi_last_query{items = RetItems});
process_iq(#iq{type = get, lang = Lang} = IQ) ->
  Txt = ?T("Incorrect request format."),
  xmpp:make_error(IQ, xmpp:err_unexpected_request(Txt, Lang)).

-spec get_last(jid(), jid(), binary())
      -> {true, non_neg_integer(), binary()} | false.
get_last(From, #jid{luser = User, lserver = Server} = To, Lang)  ->
  {Subscription, _Ask, _Groups} =
    ejabberd_hooks:run_fold(roster_get_jid_info, Server,
      {none, none, []}, [User, Server, From]),
  if (Subscription == both) or (Subscription == from) or
    (From#jid.luser == To#jid.luser) and
      (From#jid.lserver == To#jid.lserver) ->

    Pres = xmpp:set_from_to(#presence{}, To, From),
    case ejabberd_hooks:run_fold(privacy_check_packet,
      Server, allow,
      [To, Pres, out]) of
      allow ->
        get_last_info(User, Server, Lang);
      deny ->
        #stanza_error{code = ErrCode,reason = Reason}
          = xmpp:err_forbidden(),
        {error, ErrCode, Reason, []}
    end;
    true ->
      Txt = ?T("Not subscribed"),
      #stanza_error{code = ErrCode,reason = Reason}
        = xmpp:err_subscription_required(Txt, Lang),
      {error, ErrCode, Reason, Txt}
  end.

-spec get_last_info(binary(), binary(), binary())
      -> {true, non_neg_integer(), binary()} | false.
get_last_info(LUser, LServer, Lang) ->
  ?INFO_MSG("get_last_info. LUser:~p, LServer:~p~n",[LUser, LServer]),
  case ejabberd_sm:get_user_resources(LUser, LServer) of
    [] ->
      case mod_last:get_last_info(LUser, LServer) of
        {ok, TimeStamp, Status} ->
          TimeStamp2 = erlang:system_time(second),
          Sec = TimeStamp2 - TimeStamp,
          {ok, Sec, Status};
        not_found ->
          Txt = ?T("No info about last activity found"),
          #stanza_error{code = ErrCode,reason = Reason}
            = xmpp:err_internal_server_error(Txt, Lang),
          {error, ErrCode, Reason, Txt};
        {error, _Reason} ->
          Txt = ?T("Database failure"),
          #stanza_error{code = ErrCode,reason = Reason}
            = xmpp:err_internal_server_error(Txt, Lang),
          {error, ErrCode, Reason, Txt}
      end;
    _ ->
      {ok, 0, <<>>}
  end.

depends(_Host, _Opts) ->
  [{mod_last, hard}].

mod_options(_Host) ->
  [].

mod_doc() ->
  #{desc => ?T("This module adds an IQ to get multiple user's last activity.")}.