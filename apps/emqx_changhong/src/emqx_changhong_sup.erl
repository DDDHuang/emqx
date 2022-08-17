%%
%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. All Rights Reserved.
%%
%% @doc EMQ X ChangHong Business Supervisor
%%

-module(emqx_changhong_sup).

-include("emqx_changhong.hrl").

-behaviour(supervisor).

-export([start_link/1]).

-export([init/1]).

start_link(Pools) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Pools]).

init([Pools]) ->
    PoolSpec = ecpool:pool_spec(?APP, ?APP, emqx_changhong, Pools),
    {ok, {{one_for_one, 10, 100}, [PoolSpec]}}.
