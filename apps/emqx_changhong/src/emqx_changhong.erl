%%
%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. All Rights Reserved.
%%
%% @doc EMQ X CHANGHONG
%%

-module(emqx_changhong).

-behaviour(ecpool_worker).

-include("emqx_changhong.hrl").

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-export([ connect/1
        , q/1
        ]).

-export([ load/0
        , unload/0
        ]).

%% Hook Callbacks1
-export([ on_client_auth/2
        , on_client_connected/2
        , on_check_acl/4
        , on_client_disconnected/3
        , on_message_publish/1
        ]).

-define(C(K, L), proplists:get_value(K, L)).

-define(ONLINE, 1).
-define(OFFLINE, 0).
-define(DEVICE, <<"d">>).
-define(M_APP, <<"a">>).

%%--------------------------------------------------------------------
%% Load The Plugin
%%--------------------------------------------------------------------
% load() ->
%     Env = [],
%     emqx:hook('client.connected', fun ?MODULE:on_client_connected/4, [Env]),
%     emqx:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3, [Env]),
%     emqx:hook('message.publish', fun ?MODULE:on_message_publish/2, [Env]),
%     io:format("~s is loaded.~n", [?APP]), ok.

load() ->
    do_hook('client.authenticate', fun ?MODULE:on_client_auth/2),
    do_hook('client.connected', fun ?MODULE:on_client_connected/2),
    do_hook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
    do_hook('client.check_acl', fun ?MODULE:on_check_acl/4),
    do_hook('message.publish', fun ?MODULE:on_message_publish/1),
    ?LOG(info, "[Changhong] hooks loaded"),
    io:format("~s is loaded.~n", [?APP]), ok.

do_hook(Point, Callback) ->
    case emqx:hook(Point, Callback) of
        ok ->
            ?LOG(info, "[Changhong] hooks loaded"),
            ok;
        {error, already_exists} ->
            ?LOG(info, "[Changhong] hooks already loaded"),
            ok
        % {error, Reason} ->
        %     ?LOG(error, "[Changhong] add hook failed: ~p", [Point]),
        %     error(Reason)
    end.


%%-------------------------------------------------------------------
%% Unload the Plugin
%%--------------------------------------------------------------------
unload() ->
    emqx:unhook('client.authenticate', fun ?MODULE:on_client_auth/2),
    emqx:unhook('client.connected', fun ?MODULE:on_client_connected/2),
    emqx:unhook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
    emqx:unhook('client.check_acl', fun ?MODULE:on_check_acl/4),
    emqx:unhook('message.publish', fun ?MODULE:on_message_publish/1),
    ?LOG(info, "[Changhong] hooks unloaded"),
    io:format("~s is unloaded.~n", [?APP]), ok.

%%--------------------------------------------------------------------
%% Auth
%%--------------------------------------------------------------------

on_client_auth(#{clientid := <<"s:", Cid/binary>>, password := Password}, AuthResult) ->
    ?LOG(info, "[Changhong] on_client_auth: s:~0p", [Cid]),
    Cmd = [<<"GET">>, table_name(<<"security">>, Cid)],
    case q(Cmd) of
        {ok, PWDFromRedis} ->
            case check_password(Password, PWDFromRedis) of
                true ->
                    ?LOG(info, "[Changhong] on_client_auth: z:~0p success", [Cid]),
                    {stop, AuthResult#{auth_result => success, anonymous => false}};
                false ->
                    ?LOG(error, "[Changhong] on_client_auth error, s:~0p, bad pwd", [Cid]),
                    {stop, AuthResult#{auth_result => not_authorized, anonymous => false}};
                {error, Reason} ->
                    ?LOG(error, "[Changhong] on_client_auth error, s:~0p, ~0p ", [Cid, Reason]),
                    {stop, AuthResult#{auth_result => not_authorized, anonymous => false}}
            end;
        Error ->
            ?LOG(error, "[Changhong] on_client_auth error, s:~0p, ~0p", [Cid, Error]),
            {stop, AuthResult#{auth_result => not_authorized, anonymous => false}}
    end;
on_client_auth(#{clientid := <<"z:", Cid/binary>>, password := Password}, AuthResult) ->
    ?LOG(info, "[Changhong] on_client_auth: z:~0p", [Cid]),
    Cmd = [<<"GET">>, <<"cloud:security">>],
    case q(Cmd) of
        {ok, PWDFromRedis} ->
            case check_password(Password, PWDFromRedis) of
                true ->
                    ?LOG(info, "[Changhong] on_client_auth: z:~0p success", [Cid]),
                    {stop, AuthResult#{anonymous => false, auth_result => success}};
                false ->
                    ?LOG(error, "[Changhong] on_client_auth error, z:~0p, bad pwd", [Cid]),
                    {stop, AuthResult#{auth_result => not_authorized, anonymous => false}};
                {error, Reason} ->
                    ?LOG(error, "[Changhong] on_client_auth error, z:~0p, ~0p ", [Cid, Reason]),
                    {stop, AuthResult#{auth_result => not_authorized, anonymous => false}}
            end;
        Error ->
            ?LOG(error, "[Changhong] on_client_auth error, z:~0p, ~0p", [Cid, Error]),
            {stop, AuthResult#{auth_result => not_authorized, anonymous => false}}
    end;
on_client_auth(#{clientid := ID}, _AuthResult) ->
    ?LOG(debug, "[Changhong] on_client_auth unknow ~0p", [ID]),
    ok.

% support redis response with  <<"\"some_pwd\"">> or [<<"\"some_pwd\"">>]
% anyway, we need to get the pwd string
check_password(PWD, [PWDFromRedis]) when is_binary(PWDFromRedis)->
    check_password(PWD, PWDFromRedis);
check_password(PWD, PWDFromRedis) when is_binary(PWDFromRedis) ->
    try
        PWD == emqx_json:decode(PWDFromRedis)
    catch _E:_R ->
        case PWD == PWDFromRedis of
            true -> true;
            false -> {error, bad_pwd}
        end
    end;
check_password(_PWD, _PWDFromRedis) ->
    {error, unknow_pwd}.

%%--------------------------------------------------------------------
%% Client Connected
%%--------------------------------------------------------------------
on_client_connected(ClientInfo = #{clientid := <<"d:", Sn/binary>> = ClientId}, _ConnInfo) ->
    Topic = binary:replace(<<"d/${sn}/i">>, <<"${sn}">>, Sn),
    case legality_topic(Topic) of
        false ->
            Host = maps:get(peerhost, ClientInfo, undefined),
            Username = maps:get(username, ClientInfo, undefined),
            ?LOG(error, "[changhong] bad sn ~p , ~p is illegal, host ~0p, username ~0p",
                [?FUNCTION_NAME, ClientId, Host, Username]);
        true ->
            TopicTables = [emqx_topic:parse(Topic, #{qos => 1})],
            self() ! {subscribe, TopicTables},
            Value = [<<"state">>, ?ONLINE, <<"online_at">>, erlang:system_time(second), <<"offline_at">>, undefined],
            Cmd1 = [<<"HMSET">>, table_name(<<"device">>, Sn) | Value],
            Cmd2 = [<<"HSET">>, table_name(<<"node:mqtt">>, a2b(node())), Sn, erlang:system_time(second)],
            qp([Cmd1, Cmd2]),
            publish_state(ClientId, Sn, ?ONLINE)
    end;
on_client_connected(ClientInfo = #{clientid := <<"a:", Uid/binary>>}, _ConnInfo) ->
    _ = maybe_log_clientid_error(ClientInfo),
    ?LOG(info, "[Changhong] auto subscribe: a:~0p", [Uid]),
    auto_subscribe(Uid);
on_client_connected(ClientInfo = #{clientid := <<"s:", Uid/binary>>}, _ConnInfo) ->
    _ = maybe_log_clientid_error(ClientInfo),
    ?LOG(info, "[Changhong] auto subscribe: s:~0p", [Uid]),
    auto_subscribe(Uid);
on_client_connected(ClientInfo, _ConnInfo) ->
    _ = maybe_log_clientid_error(ClientInfo),
    ok.

maybe_log_clientid_error(ClientInfo = #{clientid := ClientId}) ->
    case legality_topic(ClientId) of
        false ->
            Host = maps:get(peerhost, ClientInfo, undefined),
            Username = maps:get(username, ClientInfo, undefined),
            ?LOG(error, "[changhong] bad sn ~p , ~p is illegal, host ~0p, username ~0p",
                [?FUNCTION_NAME, ClientId, Host, Username]);
        true ->
            ok
    end.

%%--------------------------------------------------------------------
%% Client auto subscribe
%%--------------------------------------------------------------------
auto_subscribe(Uid) ->
    I = binary:replace(<<"a/${uid}/i">>, <<"${uid}">>, Uid),
    S = binary:replace(<<"a/${uid}/s">>, <<"${uid}">>, Uid),
    TopicTables = [
        emqx_topic:parse(I, #{qos => 1}),
        emqx_topic:parse(S, #{qos => 1})
    ],
    self() ! {subscribe, TopicTables}.

%%--------------------------------------------------------------------
%% Client DisConnected
%%--------------------------------------------------------------------
on_client_disconnected(_Client, auth_failure, _Env) ->
    ok;
on_client_disconnected(#{clientid := ClientId = <<"d:", Sn/binary>>}, _Reason, _) ->
    Value = [<<"state">>, ?OFFLINE, <<"offline_at">>, erlang:system_time(second)],
    Cmd1 = [<<"HMSET">>, table_name(<<"device">>, Sn) | Value],
    Cmd2 = [<<"HDEL">>, table_name(<<"node:mqtt">>, a2b(node())), Sn],
    qp([Cmd1, Cmd2]),
    _ = publish_state(ClientId, Sn, ?OFFLINE),
    ok;
on_client_disconnected(_Client, _Reason, _Env) ->
    ok.

%%--------------------------------------------------------------------
%% Check ACL. Bad sn will be denied
%%--------------------------------------------------------------------
on_check_acl(ClientInfo = #{clientid := ClientId}, publish, Topic, _AclResult) ->
    case legality_topic(ClientId) andalso legality_topic(Topic) of
        true ->
            io:format("ClientInfo: ~p~n", [ClientInfo]),
            ok;
        false ->
            Host = maps:get(peerhost, ClientInfo, undefined),
            Username = maps:get(username, ClientInfo, undefined),
            ?LOG(warning,
                "[changhong] bad sn try pub ~0p , client id  ~p is illegal, host ~0p, username ~0p",
                [Topic, ClientId, Host, Username]),
            {stop, deny}
    end;
on_check_acl(_ClientInfo, _Sub, _Topic, _AclResult) ->
    ok.

%%--------------------------------------------------------------------
%% Publish Message
%%--------------------------------------------------------------------
on_message_publish(Msg = #message{topic = Topic}) ->
    Filters = [{<<"d/+/s">>, mstate},
               {<<"d/+/m">>, dmsg},
               {<<"x/+/m">>, dmsg},
               {<<"x/+/s">>, xstate},
               {<<"d/+/i">>, msg},
               {<<"d/+/a">>, dalarm},
               {<<"x/+/a">>, dalarm},
			   {<<"router/#">>, router}
            ],
    case filter(Filters, Topic) of
        false -> {ok, Msg};
        Type ->
            case on_message(Msg, Type) of
                ok -> {ok, Msg};
                {ok, Msg1} -> {ok, Msg1}
            end
    end.

filter([], _Topic) ->
    false;
filter([{Filter, Type} | Filters], Topic) ->
    case emqx_topic:match(Topic, Filter) of
        true -> Type;
        false -> filter(Filters, Topic)
    end.


%% mqtt设备发布状态消息
on_message(#message{topic = Topic, from = From, payload = Payload}, mstate) ->
    %% send mqtt device state to app/cloud
    [_, Sn, _] = binary:split(Topic, <<"/">>, [global]),
	_ = publish_state_to_iot(From, Payload),
    Cmd = [<<"HGETALL">>, table_name(<<"bind:device">>, Sn)],
    case q(Cmd) of
        {ok, []} -> ok;
        {ok, Hash} ->
            lists:foreach(
                fun({Id, Type}) ->
                    case Type of
                        <<"app">>   -> publish_state_to_app(From, Id, Payload);
                        <<"cloud">> -> publish_state_to_cloud(From, Id, Sn, Payload)
                    end
                end, parse_bind(Hash));
        {error, Reason} -> logger:error("error: ~p", [Reason])
    end, ok;

%% 设备发布消息
on_message(#message{topic = Topic, from = From, payload = Payload}, dmsg) ->
    %% send mqtt device message to app/cloud
    [_, Sn, _] = binary:split(Topic, <<"/">>, [global]),
	_ = publish_msg_to_iot(From, Topic, Payload),
    Cmd = [<<"HGETALL">>, table_name(<<"bind:device">>, Sn)],
    case q(Cmd) of
        {ok, []} -> ok;
        {ok, Hash} ->
            lists:foreach(
                fun({Id, Type}) ->
                    case Type of
                        <<"app">>   -> publish_msg_to_app(From, Id, Sn, Payload);
                        <<"cloud">> -> publish_msg_to_cloud(From, Id, Sn, Payload)
                    end
                end, parse_bind(Hash));
        {error, Reason} -> logger:error("error: ~p", [Reason])
    end, ok;

%% 与设备影子交互
on_message(#message{topic = Topic, from = From, payload = Payload}, router) ->
    %% send mqtt device message to app/cloud
	publish_msg_to_iot(From, Topic, Payload);

%% xmpp设备发布状态消息
on_message(#message{topic = Topic, from = From, payload = Payload}, xstate) ->
    %% store xmpp device state to redis in xmpp:device
    [_, Sn, _] = binary:split(Topic, <<"/">>, [global]),
    _ = case Payload of
        <<"1">> ->
            q([<<"ZADD">>, <<"xmpp:device">>, 1, Sn]),
            publish_state(From, Sn, ?ONLINE);
        <<"0">> ->
            q([<<"ZREM">>, <<"xmpp:device">>, Sn]),
            publish_state(From, Sn, ?OFFLINE)
    end,
    ok;

%% 发布消息到mqtt/xmpp设备上
on_message(#message{topic = Topic, from = From, payload = Payload} = Msg, msg) ->

    % 1.判断emq消息 d/${sn}/i的 发送者，如果发送者的clientid(格式为a:${cid})不在redis hash列表中，则该条消息不成功。
    % 说明
    % a.redis hash的key为 device:bind:${sn}
    % b.hash中判断的key为cid
    [_, Sn, _] = binary:split(Topic, <<"/">>, [global]),
    ClientId = format_from(From),
    case check_d_msg_clientid(ClientId, Sn) of
        true ->
            %% app/cloud send message to mqtt/xmpp device
            _ =
                case q([<<"ZRANK">>, <<"xmpp:device">>, Sn]) of
                    {ok, undefined} -> ok;
                    {ok, _} ->
                        publish_msg_to_xmpp(From, Topic, Payload)
                end,
            ok;
        false ->
            {ok, Msg#message{headers = #{allow_publish => false}}}
    end;

%% mqtt设备发布告警消息
on_message(#message{topic = Topic, from = From, payload = Payload}, dalarm) ->
    [_, Sn, _] = binary:split(Topic, <<"/">>, [global]),
    Cmd = [<<"HGETALL">>, table_name(<<"bind:device">>, Sn)],
    case q(Cmd) of
        {ok, []} -> ok;
        {ok, Hash} ->
            lists:foreach(fun({Id, Type}) ->
                case Type of
                    <<"app">> ->
                        publish_msg_to_app(From, Id, Sn, Payload);
                    <<"cloud">> ->
                        publish_msg_to_cloud(From, Id, Sn, Payload)
                end
            end, parse_bind(Hash));
        {error, Reason} -> logger:error("error: ~p", [Reason])
    end,
    ok.

% on_message(_Msg, _Type) ->
    %% app/cloud send message to mqtt/xmpp device
    % ok.


table_name(Name, Val) ->
    Split = <<":">>,
    <<Name/binary, Split/binary, Val/binary>>.


publish_state(From, Sn, State) ->
    Topic = binary:replace(<<"d/${sn}/s">>, <<"${sn}">>, Sn),
    case legality_topic(Topic) of
        false ->
            ?LOG(error, "[changhong] ~p topic ~p is illegal", [?FUNCTION_NAME, Topic]);
        true ->
            %Json = [{sn, Sn}, {s, State}],
            %Payload = iolist_to_binary(mochijson2:encode(Json)),
            Len = size(Sn),
            Payload = <<Len:8, Sn/binary, State:8>>,
            Msg = emqx_message:make(From, 1, Topic, Payload),
            emqx:publish(Msg)
    end.

publish_state_to_app(From, Uid, Payload) ->
    Topic = binary:replace(<<"a/${uid}/s">>, <<"${uid}">>, Uid),
    case legality_topic(Topic) of
        false ->
            ?LOG(error, "[changhong] ~p topic ~p is illegal", [?FUNCTION_NAME, Topic]);
        true ->
            Msg = emqx_message:make(From, 1, Topic, Payload),
            logger:debug("publish_state_to_app:~p~n", [Msg]),
            emqx:publish(Msg)
    end.

publish_state_to_iot(From, Payload) ->
    Topic = <<"iot/state">>,
    Msg = emqx_message:make(From, 1, Topic, Payload),
    logger:debug("publish_state_to_iot:~p~n", [Msg]),
    emqx:publish(Msg).

publish_state_to_cloud(From, Cloud, Sn, Payload) ->
    Topic = binary:replace(binary:replace(<<"cloud/${cloud}/d/${sn}/s">>, <<"${cloud}">>, Cloud), <<"${sn}">>, Sn),
    case legality_topic(Topic) of
        false ->
            ?LOG(error, "[changhong] ~p topic ~p is illegal", [?FUNCTION_NAME, Topic]);
        true ->
            Msg = emqx_message:make(From, 1, Topic, Payload),
            logger:debug("publish_state_to_cloud:~p~n", [Msg]),
            emqx:publish(Msg)
    end.

publish_msg_to_app(From, Uid, Sn, Payload) ->
    Topic = binary:replace(<<"a/${uid}/i">>, <<"${uid}">>, Uid),
    case legality_topic(Topic) of
        false ->
            ?LOG(error, "[changhong] ~p topic ~p is illegal", [?FUNCTION_NAME, Topic]);
        true ->
            %Json = [{sn, Sn}, {payload, Payload}],
            %NewPayload = iolist_to_binary(mochijson2:encode(Json)),
            Len = size(Sn),
            NewPayload = <<Len:8, Sn/binary, Payload/binary>>,
            Msg = emqx_message:make(From, 1, Topic, NewPayload),
            logger:debug("publish_msg_to_app:~p~n", [Msg]),
            emqx:publish(Msg)
    end.

publish_msg_to_iot(From, Stopic, Payload) ->
    Topic = <<"iot/msg">>,
    Len = size(Stopic),
    NewPayload = <<Len:8, Stopic/binary, Payload/binary>>,
    Msg = emqx_message:make(From, 1, Topic, NewPayload),
    logger:debug("publish_msg_to_iot:~p~n", [Msg]),
    emqx:publish(Msg).

publish_msg_to_cloud(From, Cloud, Sn, Payload) ->
    Topic = binary:replace(binary:replace(<<"cloud/${cloud}/d/${sn}/m">>, <<"${cloud}">>, Cloud), <<"${sn}">>, Sn),
    case legality_topic(Topic) of
        false ->
            ?LOG(error, "[changhong] ~p topic ~p is illegal", [?FUNCTION_NAME, Topic]);
        true ->
            %Json = [{sn, Sn}, {payload, Payload}],
            %NewPayload = iolist_to_binary(mochijson2:encode(Json)),
            Len = size(Sn),
            NewPayload = <<Len:8, Sn/binary, Payload/binary>>,
            Msg = emqx_message:make(From, 1, Topic, NewPayload),
            logger:debug("publish_msg_to_cloud:~p~n", [Msg]),
            emqx:publish(Msg)
    end.

publish_msg_to_xmpp(From, Topic, Payload) ->
    Head = <<"xmpp/">>,
    Msg = emqx_message:make(From, 1, <<Head/binary, Topic/binary>>, Payload),
    logger:debug("publish_msg_to_xmpp:~p~n", [Msg]),
    emqx:publish(Msg).

legality_topic(Topic) ->
    case unicode:characters_to_binary(Topic) of
        Data when is_binary(Data) ->
            true;
        _ ->
            false
    end.

parse_bind(Hash) -> parse_bind(Hash, []).

parse_bind([], Acc) -> Acc;
parse_bind([Id, Type | Hash], Acc) -> parse_bind(Hash, [{Id, Type} | Acc]).

%%--------------------------------------------------------------------
%% Redis Connect/Query
%%--------------------------------------------------------------------

connect(Opts) ->
    Sentinel = ?C(sentinel, Opts),
    io:format("start changhong ~p ~n", [Sentinel]),
    Host = case Sentinel =:= "" of
        true  ->
            ?C(host, Opts);
        false ->
            _ = eredis_sentinel:start_link([{?C(host, Opts), ?C(port, Opts)}]),
            "sentinel:"++ Sentinel
    end,
    eredis:start_link(Host,
                      ?C(port, Opts),
                      ?C(database, Opts),
                      ?C(password, Opts),
                      no_reconnect).

%% Redis Query.
q(Cmd) ->
    ?LOG(debug, "[changhong] redis command: ~0p", [Cmd]),
    %% logger:debug("q-cmd:~p", [Cmd]),
    Res = ecpool:with_client(?APP, fun(C) -> eredis:q(C, Cmd) end),
    ?LOG(info, "[changhong] redis command: ~0p  result: ~0p", [Cmd, Res]),
    Res.

qp(PipeLine) ->
    ?LOG(debug, "[changhong] redis query: ~0p", [PipeLine]),
    Res = ecpool:with_client(?APP, fun(C) -> eredis:qp(C, PipeLine) end),
    ?LOG(info, "[changhong] redis query: ~0p  result: ~0p", [PipeLine, Res]),
    Res.

a2b(A) -> erlang:atom_to_binary(A, utf8).

% 1.发送topic为d/${sn}/i的发送者，除了以z:开头的，其它都需要判断发送者的clientid是否在redis hash列表中，若不在，则不允许发送
% a.redis hash的key为 device:bind:${sn}
% b.hash中判断的key为cid
check_d_msg_clientid(Cid = <<"z:", _/binary>>, _Sn) ->
    ?LOG(debug, "[changhong] check d msg clientid:~p success", [Cid]),
    true;
check_d_msg_clientid(Cid, Sn) ->
    ?LOG(debug, "[changhong] check d msg clientid:~p ", [Cid]),
    case binary:split(Cid, <<":">>) of
        [_, Cid1] ->
            case q([<<"HGET">>, table_name(<<"bind:device">>, Sn), Cid1]) of
                {ok, undefined} ->
                    ?LOG(debug, "[changhong] check d msg clientid:~p failed, not found", [Cid]),
                    false;
                {ok, _} ->
                    ?LOG(debug, "[changhong] check d msg clientid:~p success", [Cid]),
                    true
            end;
        _ ->
            ?LOG(debug, "[changhong] check d msg clientid:~p failed, bad client id", [Cid]),
            false
    end.

format_from(From) when is_binary(From) orelse is_atom(From) ->
    From;
format_from(From) ->
    From.
