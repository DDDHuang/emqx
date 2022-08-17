%%
%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. All Rights Reserved.
%%
%% @doc EMQ X ChangHong Business Application
%%

-module(emqx_changhong_app).

-behaviour(application).

-emqx_plugin(?MODULE).

-include("emqx_changhong.hrl").

-export([start/2, stop/1]).

start(_Type, _Args) ->
	Pools = application:get_env(?APP, server, []),
    {ok, Sup} = emqx_changhong_sup:start_link(Pools),
    ?APP:load(),
    {ok, Sup}.

stop(_State) ->
    ?APP:unload().
