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
  process_sm_iq/1,
  depends/2,
  mod_opt_type/1,
  mod_options/1,
  mod_doc/0
]).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("mod_privacy.hrl").
-include("translate.hrl").

-define(LAST_CACHE, last_activity_cache).

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_MULTI_LAST, ?MODULE, process_sm_iq).
stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MULTI_LAST).

%%%
%%% Serve queries about user last online
%%%
-spec process_sm_iq(iq()) -> iq().
process_sm_iq(#iq{type = set, lang = Lang} = IQ) ->
	Txt = ?T("Value 'set' of 'type' attribute is not allowed"),
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_sm_iq({#iq{type = get, sub_els = [#multi_last_query{}]} = _IQ}) ->
	ok.

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


