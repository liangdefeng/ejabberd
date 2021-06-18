%%%-------------------------------------------------------------------
%%% @author Peter Liang
%%% @copyright (C) 2021, Peter Liang
%%% @doc
%%%
%%% @end
%%% Created : 14. Jun 2021 4:38 PM
%%%-------------------------------------------------------------------
-module(mod_muc_invite).

-author('defeng.liang.cn@gmail.com').

-behaviour(gen_mod).

-export([start/2, stop/1,
  process_muc_invite/7,
  depends/2,
  mod_options/1,
  mod_doc/0
]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("translate.hrl").

start(Host, _Opts) ->
  ejabberd_hooks:add(muc_invite, Host, ?MODULE,
    process_muc_invite, 30).

stop(Host) ->
  ejabberd_hooks:delete(muc_invite, Host,
    ?MODULE, process_muc_invite, 30).

process_muc_invite(#message{sub_els = SubEls}, RoomJid, _Config, _From, To, Reason, _Pkg) ->
  Msg = #message{from = RoomJid,
    to = To,
    type = normal,
    body = [#text{data = Reason}],
    sub_els = SubEls},
  {stop, Msg}.

depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].

mod_doc() ->
  #{desc => ?T("This module adds an IQ to get multiple user's last activity.")}.
