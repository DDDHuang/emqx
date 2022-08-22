-module(emqx_changhong_SUITE).

-define(APP, emqx_changhong).

-compile(export_all).

-include_lib("emqx/include/emqx.hrl").

-include_lib("eunit/include/eunit.hrl").

-include_lib("common_test/include/ct.hrl").

-define(ONLINE, 1).
-define(OFFLINE, 0).
-define(DEVICE, <<"d">>).
-define(M_APP, <<"a">>).

all() ->
    [].
    % [
    % {group, state},
    %  {group, publish}
    % ].

groups() ->
    [
        {state, [sequence], [connect, disconnect]},
        {publish, [sequence], [pub_state,
                               pub_device_msg,
                               pub_xmpp_device_msg,
                               pub_xmpp_device_state,
                               pub_msg_xmpp_device,
                               pub_alarm_device,
                               pub_alarm_xmpp_device,
                               pub_router]}
    ].

init_per_suite(Config) ->
    emqx_ct_helpers:start_apps([emqx, emqx_changhong]),
    Config.

end_per_suite(_Config) ->
    emqx_ct_helpers:stop_apps([emqx_changhong, emqx]).

init_per_testcase(_, Config) ->
    emqx_logger:set_log_level(debug),
    clean_data(),
    Config.

end_per_testcase(_, Config) ->
    clean_data(),
    Config.

clean_data() ->
    emqx_changhong:q(["FLUSHDB"]).

connect(_Config) ->
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"d/+/s">>, 1),

    {ok, Dev} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"d:1001">>}]),
    {ok, _} = emqx_client:connect(Dev),
    {ok, State0} = emqx_changhong:q([<<"HGETALL">>, <<"device:1001">>]),
    State = parse(State0),
    ?assertEqual(proplists:get_value(<<"state">>, State), <<"1">>),

    timer:sleep(50),

    DPid = ets:lookup_element(emqx_session, <<"d:1001">>, 2),
    ?assertEqual(length(emqx_broker:subscriptions(DPid)), 1),

    {ok, App} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"a:2001">>}]),
    {ok, _} = emqx_client:connect(App),
    timer:sleep(50),
    APid = ets:lookup_element(emqx_session, <<"a:2001">>, 2),
    ?assertEqual(length(emqx_broker:subscriptions(APid)), 2),

    receive
        {publish, #{topic := Topic}} ->
            ?assertEqual(<<"d/1001/s">>, Topic)
    after 1000 ->
            ?assert(false, <<"not receive">>)
    end,
    emqx_client:disconnect(Receive),
    emqx_client:disconnect(Dev),
    emqx_client:disconnect(App).

disconnect(_Config) ->
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"d/+/s">>, 1),

    {ok, Dev} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"d:1001">>}]),
    {ok, _} = emqx_client:connect(Dev),
    emqx_client:disconnect(Dev),
    timer:sleep(50),

    {ok, State0} = emqx_changhong:q([<<"HGETALL">>, <<"device:1001">>]),
    State = parse(State0),
    ?assertEqual(proplists:get_value(<<"state">>, State), <<"0">>),

    receive
        {publish, #{topic := Topic}} ->
            ?assertEqual(<<"d/1001/s">>, Topic)
    after 1000 ->
            ?assert(false, <<"not receive">>)
    end,
    emqx_client:disconnect(Receive).

pub_state(_Config) ->
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"aaa">>, <<"app">>]),
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"bbb">>, <<"cloud">>]),
    timer:sleep(50),
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"iot/state">>, 1),
    emqx_client:subscribe(Receive, <<"a/+/s">>, 1),
    emqx_client:subscribe(Receive, <<"cloud/+/d/+/s">>, 1),

    {ok, Dev} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"d:1001">>}]),
    {ok, _} = emqx_client:connect(Dev),

    timer:sleep(50),
    ?assertEqual(3, length(flush())),
    emqx_client:disconnect(Receive),
    emqx_client:disconnect(Dev).

pub_device_msg(_Config) ->
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"aaa">>, <<"app">>]),
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"bbb">>, <<"cloud">>]),
    timer:sleep(50),
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"a/+/i">>, 1),
    emqx_client:subscribe(Receive, <<"cloud/+/d/+/m">>, 1),

    {ok, Dev} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"d:1001">>}]),
    {ok, _} = emqx_client:connect(Dev),
    emqx_client:publish(Dev, <<"d/1001/m">>, <<"a">>),

    timer:sleep(50),
    ?assertEqual(2, length(flush())),
    emqx_client:disconnect(Receive),
    emqx_client:disconnect(Dev).

pub_xmpp_device_msg(_Config) ->
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"aaa">>, <<"app">>]),
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"bbb">>, <<"cloud">>]),
    timer:sleep(50),
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"a/+/i">>, 1),
    emqx_client:subscribe(Receive, <<"cloud/+/d/+/m">>, 1),

    {ok, Dev} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"d:1001">>}]),
    {ok, _} = emqx_client:connect(Dev),
    emqx_client:publish(Dev, <<"x/1001/m">>, <<"a">>),

    timer:sleep(50),
    ?assertEqual(2, length(flush())),
    emqx_client:disconnect(Receive),
    emqx_client:disconnect(Dev).

pub_xmpp_device_state(_Config) ->
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"aaa">>, <<"app">>]),
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"bbb">>, <<"cloud">>]),
    timer:sleep(50),
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"iot/state">>, 1),
    emqx_client:subscribe(Receive, <<"a/+/s">>, 1),
    emqx_client:subscribe(Receive, <<"cloud/+/d/+/s">>, 1),

    emqx_client:publish(Receive, <<"x/1001/s">>, <<"1">>),
    timer:sleep(50),
    {ok, State} = emqx_changhong:q([<<"ZRANGE">>, <<"xmpp:device">>, 0, -1]),
    ?assertEqual(1, length(State)),

    emqx_client:publish(Receive, <<"x/1001/s">>, <<"0">>),
    timer:sleep(50),
    {ok, State1} = emqx_changhong:q([<<"ZRANGE">>, <<"xmpp:device">>, 0, -1]),
    ?assertEqual(0, length(State1)),

    ?assertEqual(6, length(flush())),
    emqx_client:disconnect(Receive).

pub_msg_xmpp_device(_Config) ->
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"xmpp/#">>, 1),

    emqx_client:publish(Receive, <<"x/1001/s">>, <<"1">>),
    timer:sleep(50),

    emqx_client:publish(Receive, <<"d/1001/i">>, <<"1">>),
    timer:sleep(50),

    ?assertEqual(1, length(flush())),
    emqx_client:disconnect(Receive).

pub_alarm_device(_Config) ->
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"aaa">>, <<"app">>]),
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"bbb">>, <<"cloud">>]),
    timer:sleep(50),
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"a/+/i">>, 1),
    emqx_client:subscribe(Receive, <<"cloud/+/d/+/m">>, 1),
    timer:sleep(50),

    emqx_client:publish(Receive, <<"d/1001/a">>, <<"1">>),
    timer:sleep(50),

    ?assertEqual(2, length(flush())),
    emqx_client:disconnect(Receive).

pub_alarm_xmpp_device(_Config) ->
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"aaa">>, <<"app">>]),
    emqx_changhong:q([<<"HSET">>, <<"bind:device:1001">>, <<"bbb">>, <<"cloud">>]),
    timer:sleep(50),
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"a/+/i">>, 1),
    emqx_client:subscribe(Receive, <<"cloud/+/d/+/m">>, 1),
    timer:sleep(50),

    emqx_client:publish(Receive, <<"x/1001/a">>, <<"1">>),
    timer:sleep(50),

    ?assertEqual(2, length(flush())),
    emqx_client:disconnect(Receive).

pub_router(_Config) ->
    {ok, Receive} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"revc">>}]),
    {ok, _} = emqx_client:connect(Receive),
    emqx_client:subscribe(Receive, <<"iot/msg">>, 1),

    emqx_client:publish(Receive, <<"router/aaa">>, <<"1">>),
    timer:sleep(50),

    ?assertEqual(1, length(flush())),
    emqx_client:disconnect(Receive).


parse(Hash) -> parse(Hash, []).
parse([], Acc) -> Acc;
parse([Key, Val| Tail], Acc) -> parse(Tail, [{Key, Val}| Acc]).

flush() ->
    flush([]).
flush(Msgs) ->
    receive
        M -> flush([M|Msgs])
    after
        0 -> lists:reverse(Msgs)
    end.

% queue_auto_sub(Config) ->
%     Connection = ?config(connection, Config),
%     [eredis:q(Connection, ["HSET", Key, Filed, Value]) || {Key, Filed, Value} <- ?Queue],

%     %%step 1 publish messages
%     {ok, Publisher} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"pub">>}]),
%     {ok, _} = emqx_client:connect(Publisher),
%     timer:sleep(10),
%     emqx_client:publish(Publisher, <<"queue/topic">>, <<"a">>, [{qos, 1}, {retain, false}]),
%     timer:sleep(10),
%     %%step 2 get message
%     {ok, Subscriber} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"squeue">>}]),
%     {ok, _} = emqx_client:connect(Subscriber),
%     timer:sleep(100),
%     emqx_client:subscribe(Subscriber, <<"queue/topic">>, 1),
%     receive
%         {publish, _Topic, A} ->
%             ?assertEqual(<<"a">>, A)
%     after 1000 ->
%             false
%     end,
%     emqx_client:disconnect(Publisher),
%     emqx_client:disconnect(Subscriber),
%     timer:sleep(10),
%     {ok, Msgids} = eredis:q(Connection, ["ZRANGE", <<"mqtt:msg:queue/topic">>, 0, -1]),
%     ?assertEqual(length(Msgids), 0),
%     timer:sleep(10),
%     eredis:q(Connection, ["FLUSHDB"]),
%     ok.

% queue_receive(Config) ->
%     Connection = ?config(connection, Config),
%     {ok, Subscriber} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"squeue">>}]),
%     {ok, _} = emqx_client:connect(Subscriber),
%     emqx_client:subscribe(Subscriber, <<"queue/topic">>, 1),

%     {ok, Publisher} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"pub">>}]),
%     {ok,  _} = emqx_client:connect(Publisher),
%     timer:sleep(100),
%     emqx_client:publish(Publisher, <<"queue/topic">>, <<"a">>, [{qos, 1}, {retain, false}]),
%     timer:sleep(100),
%     receive
%         {publish, _, A} ->
%             ?assertEqual(<<"a">>, A)
%     after 1000 ->
%         false
%     end,
%     emqx_client:disconnect(Subscriber),
%     timer:sleep(1000),

%     emqx_client:publish(Publisher, <<"queue/topic">>, <<"b">>, [{qos, 1}, {retain, false}]),
%     {ok, Subscriber1} = emqx_client:start_link([{host, "localhost"}, {client_id, <<"squeue1">>}]),
%     {ok, _} = emqx_client:connect(Subscriber1),

%     emqx_client:subscribe(Subscriber1, <<"queue/topic">>, qos1),
%     timer:sleep(1000),
%     receive
%         {publish, _, B} ->
%             ?assertEqual(<<"b">>, B)
%     after 1000 ->
%             false
%     end,
%     timer:sleep(1000),
%     emqx_client:disconnect(Subscriber1),
%     emqx_client:disconnect(Publisher),
%     timer:sleep(10),
%     {ok, Msgids} = eredis:q(Connection, ["ZRANGE", <<"mqtt:msg:queue/topic">>, 0, -1]),
%     ?assertEqual(length(Msgids), 0),
%     timer:sleep(10),
%     eredis:q(Connection, ["FLUSHDB"]),
%     ok.

