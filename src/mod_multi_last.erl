%%%----------------------------------------------------------------------
%%% File    : mod_multi_last.erl
%%% Author  : Peter Liang
%%%----------------------------------------------------------------------

-module(mod_multi_last).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([
  start/2,
  stop/1,
  process_local_iq/1,
  depends/2,
  mod_opt_type/1,
  mod_options/1,
  mod_doc/0
]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("mod_privacy.hrl").
-include("translate.hrl").
-include("ejabberd_sql_pt.hrl").

-define(LAST_CACHE, last_activity_cache).

-define(NS_MULTI_LAST, <<"jabber:iq:multi:last">>).

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_MULTI_LAST, ?MODULE, process_local_iq).
stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MULTI_LAST).

%%%
%%% Serve queries about user last online
%%%
-spec process_local_iq(iq()) -> iq().
process_local_iq(#iq{type = set, lang = Lang} = IQ) ->
	Txt = ?T("Value 'set' of 'type' attribute is not allowed"),
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_local_iq(#iq{type = get, sub_els = [#multi_last_query{items = Items}]} = IQ) ->
  RetItems = lists:filtermap(
    fun(Item) ->
      #multi_last_item{jid = Jid} = Item,
      #jid{luser = LUser, lserver = LServer} = Jid,
      case get_last(LUser, LServer) of
        {ok, TimeStamp, Status} ->
          {true, #multi_last_item{jid = Jid, seconds = TimeStamp, status = Status}};
        _ ->
          {true, #multi_last_item{jid = Jid}}
      end
    end,
    Items),
  xmpp:make_iq_result(IQ, #multi_last_query{items = RetItems});
process_local_iq(#iq{type = get, lang = Lang} = IQ) ->
  Txt = ?T("Incorrect request format."),
  xmpp:make_error(IQ, xmpp:err_unexpected_request(Txt, Lang)).

get_last(LUser, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(seconds)d, @(state)s from last"
    " where username=%(LUser)s and %(LServer)H")) of
    {selected, []} ->
      error;
    {selected, [{TimeStamp, Status}]} ->
      {ok, TimeStamp, Status};
    _Reason ->
      {error, db_failure}
  end.

depends(_Host, _Opts) ->
  [].

mod_opt_type(db_type) ->
  econf:db_type(?MODULE);
mod_opt_type(use_cache) ->
  econf:bool();
mod_opt_type(cache_size) ->
  econf:pos_int(infinity);
mod_opt_type(cache_missed) ->
  econf:bool();
mod_opt_type(cache_life_time) ->
  econf:timeout(second, infinity).

mod_options(Host) ->
  [{db_type, ejabberd_config:default_db(Host, ?MODULE)},
    {use_cache, ejabberd_option:use_cache(Host)},
    {cache_size, ejabberd_option:cache_size(Host)},
    {cache_missed, ejabberd_option:cache_missed(Host)},
    {cache_life_time, ejabberd_option:cache_life_time(Host)}].

mod_doc() ->
  #{desc =>
  ?T("This module adds support for "
  "https://xmpp.org/extensions/xep-0012.html"
  "[XEP-0012: Last Activity]. It can be used "
  "to discover when a disconnected user last accessed "
  "the server, to know when a connected user was last "
  "active on the server, or to query the uptime of the ejabberd server."),
    opts =>
    [{db_type,
      #{value => "mnesia | sql",
        desc =>
        ?T("Same as top-level 'default_db' option, but applied to this module only.")}},
      {use_cache,
        #{value => "true | false",
          desc =>
          ?T("Same as top-level 'use_cache' option, but applied to this module only.")}},
      {cache_size,
        #{value => "pos_integer() | infinity",
          desc =>
          ?T("Same as top-level 'cache_size' option, but applied to this module only.")}},
      {cache_missed,
        #{value => "true | false",
          desc =>
          ?T("Same as top-level 'cache_missed' option, but applied to this module only.")}},
      {cache_life_time,
        #{value => "timeout()",
          desc =>
          ?T("Same as top-level 'cache_life_time' option, but applied to this module only.")}}]}.


