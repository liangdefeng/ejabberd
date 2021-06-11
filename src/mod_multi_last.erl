%%%----------------------------------------------------------------------
%%% File    : mod_multi_last.erl
%%% Author  : Peter Liang
%%%----------------------------------------------------------------------

-module(mod_multi_last).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1,
  process_local_iq/1,
  get_last/2,
  depends/2,
  mod_options/1,
  mod_doc/0
]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("mod_privacy.hrl").
-include("translate.hrl").

-define(LAST_CACHE, last_activity_cache).

-define(NS_MULTI_LAST, <<"jabber:iq:multi:last">>).

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
          ?NS_MULTI_LAST, ?MODULE, process_local_iq).
stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host,
          ?NS_MULTI_LAST).

-spec process_local_iq(iq()) -> iq().
process_local_iq(#iq{type = set, lang = Lang} = IQ) ->
	Txt = ?T("Value 'set' of 'type' attribute is not allowed"),
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_local_iq(#iq{type = get, from = From,
  sub_els = [#multi_last_query{items = Items}]} = IQ) ->
  RetItems = lists:filtermap(
    fun(Item) ->
      #multi_last_item{jid = ToJid} = Item,
      case get_last(From, ToJid) of
        {ok, TimeStamp, Status} ->
          {true, #multi_last_item{jid = ToJid,
                                  seconds = TimeStamp,
                                  status = Status}};
        _ ->
          {true, #multi_last_item{jid = ToJid}}
      end
    end,
    Items),
  xmpp:make_iq_result(IQ, #multi_last_query{items = RetItems});
process_local_iq(#iq{type = get, lang = Lang} = IQ) ->
  Txt = ?T("Incorrect request format."),
  xmpp:make_error(IQ, xmpp:err_unexpected_request(Txt, Lang)).

-spec get_last(jid(), jid())
      -> {true, non_neg_integer(), binary()} | false.
get_last(From, To)  ->
  User = To#jid.luser,
  Server = To#jid.lserver,
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
        get_last_info(User, Server);
      deny ->
        ?INFO_MSG("privacy_check_packet is deny. From:~p, To:~p~n",[From, To]),
        false
    end;
    true ->
      ?INFO_MSG("Subscription:~p, From:~p, To:~p~n",[Subscription, From, To]),
      false
  end.

-spec get_last_info(binary(), binary())
      -> {true, non_neg_integer(), binary()} | false.
get_last_info(LUser, LServer) ->
  case ejabberd_sm:get_user_resources(LUser, LServer) of
    [] ->
      case mod_last:get_last_info(LUser, LServer) of
        {ok, TimeStamp, Status} ->
          TimeStamp2 = erlang:system_time(second),
          Sec = TimeStamp2 - TimeStamp,
          {true, Sec, Status};
        Other ->
          ?INFO_MSG("mod_last:get_last_info is ~p~n",[Other]),
          false
      end;
    _ ->
      {true, 0, <<>>}
  end.

depends(_Host, _Opts) ->
  [mod_last].

mod_options(_Host) ->
  [].

mod_doc() ->
  #{desc => ?T("This module adds an IQ to get multiple user's last activity.")}.