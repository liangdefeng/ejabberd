%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_ext.erl
%%% Author  : Peter Liang <defeng.liang.cn@gmail.com>
%%% Purpose : Authentication using external web service.
%%% Created : 1 Feb 2021 Peter Liang <defeng.liang.cn@gmail.com>
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_auth_ext).

-author('Peter Liang').

-behaviour(ejabberd_auth).

-export([
  start/1,
  stop/1,
  check_password/4,
  store_type/1,
  plain_password_required/1,
  user_exists/2,
  send_request/2,
  generate_body/2,
  use_cache/1
]).

-include_lib("xmpp/include/xmpp.hrl").
-include_lib("xmerl/include/xmerl.hrl").
-include("logger.hrl").

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(_Host) -> ok.
stop(_Host) -> ok.

plain_password_required(_Host) -> true.

store_type(_Host) -> external.

check_password(User, AuthzId, Server, Token) ->
  if AuthzId /= <<>> andalso AuthzId /= User -> {nocache, false};
    true ->
      if Token == <<"">> -> {nocache, false};
        true ->
          Res = check_user_token(User, Token),
          Rule = ejabberd_option:jwt_auth_only_rule(Server),
          case acl:match_rule(Server, Rule, jid:make(User, Server, <<"">>)) of
            deny ->
              {nocache, Res};
            allow ->
              {nocache, {stop, Res}}
          end
      end
  end.

user_exists(_User, _Host) -> {nocache, false}.

use_cache(_) ->
  false.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
check_user_token(User, Token) ->
  ?DEBUG("check_user_token start. User:~p, Token:~p~n", [User, Token]),
  _AppName = "bioChat Android",
  _SecretKey = "asd923rfn32asf9dns",
  send_request(User, Token).

send_request(User, Token) ->
  ?DEBUG("send_request start", []),
  Url = ejabberd_option:ext_auth_url(),
  Method = post,
  Headers = [],
  ContentType = "application/soap+xml; charset=utf-8",
  Body = generate_body(User, Token),
  Request = {Url, Headers, ContentType, Body},
  HTTPOptions = [],
  Options = [],
  case httpc:request(Method, Request, HTTPOptions, Options) of
    {ok, Result} ->
      {{_, HttpStatusCode, _}, _, ResultBody} = Result,
      case HttpStatusCode of
        200 ->
          case extract_result(ResultBody) of
            pass ->
              true;
            _ ->
              false
          end;
        _ ->
          ?WARNING_MSG("Http code isn't 200. http_code:~p~n", [HttpStatusCode]),
          false
      end;
    {error, Reason} ->
      ?WARNING_MSG("Error occurs. reason:~p~n", [Reason]),
      false;
    Unknown ->
      ?WARNING_MSG("Error occurs. unknown:~p~n", [Unknown]),
      false
  end.

generate_body(User, Token) ->
  ?DEBUG("generate_body start", []),
  AppName = ejabberd_option:ext_auth_app_name(),
  SecretKey = ejabberd_option:ext_auth_secret_key(),
  Prolog = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>"],
  Xml = #xmlElement{
    name = 'soap12:Envelope',
    attributes = [
      {'xmlns:xsi', "http://www.w3.org/2001/XMLSchema-instance"},
      {'xmlns:xsd', "http://www.w3.org/2001/XMLSchema"},
      {'xmlns:soap12', "http://www.w3.org/2003/05/soap-envelope"}
    ],
    content = [#xmlElement{
      name = 'soap12:Body',
      content = [#xmlElement{
        name = 'CheckIMEIbyToken',
        attributes = [{'xmlns', "http://www.mybiodentity.com/"}],
        content = [
          {'imei', [#xmlText{value = User, type = cdata}]},
          {'token', [#xmlText{value = Token, type = cdata}]},
          {'appName', [#xmlText{value = AppName, type = cdata}]},
          {'SecretKey', [#xmlText{value = SecretKey, type = cdata}]}
        ]
      }]
    }]
  },
  list_to_binary(xmerl:export_simple([Xml], xmerl_xml, [{prolog, Prolog}])).

extract_result(ResultBody) ->
  ?DEBUG("extract_result start", []),
  try
    {
      #xmlElement{
        content = [#xmlElement{
          content = [#xmlElement{
            content = [#xmlElement{
              content = [#xmlText{
                value = ResultContent
              }]
            }]
          }]
        }]
      },
      _Rest
    } = xmerl_scan:string(ResultBody),
    list_to_atom(string:lowercase(ResultContent))
  catch
    Class:Reason ->
      ?WARNING_MSG("Error occurs. class:~p, reason:~p~n", [Class, Reason]),
      error
  end.
