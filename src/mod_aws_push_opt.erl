%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_aws_push_opt).

-export([aws_access_key_id/1]).
-export([aws_secret_access_key/1]).
-export([aws_region/1]).
-export([fcm_platform_endpoint/1]).
-export([apn_platform_endpoint/1]).
-export([apn_topic/1]).
-export([apn_ttl/1]).
-export([apn_push_type/1]).
-export([apn_sandbox/1]).

aws_access_key_id(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_access_key_id, Opts).

aws_secret_access_key(Opts) ->
    gen_mod:get_opt(aws_secret_access_key, Opts).

aws_region(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_region, Opts).

fcm_platform_endpoint(Opts) when is_map(Opts) ->
    gen_mod:get_opt(fcm_platform_endpoint, Opts).

apn_platform_endpoint(Opts) when is_map(Opts) ->
    gen_mod:get_opt(apn_platform_endpoint, Opts).

apn_topic(Opts) when is_map(Opts) ->
    gen_mod:get_opt(apn_topic, Opts).

apn_ttl(Opts) when is_map(Opts) ->
    gen_mod:get_opt(apn_ttl, Opts).

apn_push_type(Opts) when is_map(Opts) ->
    gen_mod:get_opt(apn_push_type, Opts).

apn_sandbox(Opts) when is_map(Opts) ->
    gen_mod:get_opt(apn_sandbox, Opts).


