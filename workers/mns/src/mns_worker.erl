-module(mns_worker).

-export([initial_state/0, metrics/0]).

-export([gk_connect/4, set_options/3, gk_disconnect/2,
    get/3, gk_post/4, put/4, set_prefix/3, mns_register/4]).

-export([
    connect/3,
    disconnect/2,
    publish/5,
    publish/6,
    subscribe/3,
    subscribe/4,
    unsubscribe/3,
    random_client_id/3,
    random_client_ip/3,
    subscribe_to_self/4,
    publish_to_self/5,
    idle/2,
    forward/4,
    publish_to_one/6,
    publish_to_one/7,
    client/2,
    worker_id/2,
    fixed_client_id/4,
    load_client_cert/3,
    load_client_key/3,
    load_cas/3,
    get_cert_bin/1]).

% gen_mqtt stats callback
-export([stats/2]).

% gen_mqtt callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    on_connect/1,
    on_connect_error/2,
    on_disconnect/1,
    on_subscribe/2,
    on_unsubscribe/2,
    on_publish/3]).

-include_lib("public_key/include/public_key.hrl").

-record(state, {mqtt_fsm, client}).
-record(mqtt, {action}).

-behaviour(gen_emqtt).
























-type meta() :: [{Key :: atom(), Value :: any()}].
-type http_options() :: list().

-record(gkstate,
    { gk_connection = undefined
    , prefix = "default"
    , http_options = [] :: http_options()
    , network_mac
    , network_id
    }).

-type gkstate() :: #gkstate{}.

-define(TIMED(Name, Expr),
    (fun () ->
        StartTime = os:timestamp(),
        Result = Expr,
        Value = timer:now_diff(os:timestamp(), StartTime),
        mzb_metrics:notify({Name, histogram}, Value),
        Result
    end)()).

-spec initial_state() -> gkstate().
initial_state() ->
    application:set_env(hackney, use_default_pool, false),
    #state{},
    #gkstate{}.

init(State) ->  % init gen_mqtt
    {A,B,C} = os:timestamp(),
    random:seed(A,B,C),
    {ok, State}.

-spec metrics() -> list().
metrics() -> metrics("default").

metrics(Prefix) ->
    [
        {group, "HTTP (" ++ Prefix ++ ")", [
            {graph, #{title => "HTTP Response",
                      units => "N",
                      metrics => [{Prefix ++ ".http_ok", counter}, {Prefix ++ ".http_fail", counter}, {Prefix ++ ".other_fail", counter}]}},
            {graph, #{title => "HTTP Latency",
                      units => "microseconds",
                      metrics => [{Prefix ++ ".http_latency", histogram}]}}
        ]},
        {group, "MQTT Pub to Sub Latency", [
            {graph, #{title => "Pub to Sub Latency (QoS 0)", metrics => [{"mqtt.message.pub_to_sub.latency", histogram}]}},
            {graph, #{title => "Pub to Sub Latency (QoS 1)", metrics => [{"mqtt.message.pub_to_sub.latency.qos1", histogram}]}},
            {graph, #{title => "Pub to Sub Latency (QoS 2)", metrics => [{"mqtt.message.pub_to_sub.latency.qos2", histogram}]}}
        ]},
        {group, "MQTT Publishers QoS 1", [
            % QoS 1 Publisher flow
            {graph, #{title => "QoS 1: Publish to Puback latency", metrics => [{"mqtt.publisher.qos1.puback.latency", histogram}]}},
            {graph, #{title => "QoS 1: Pubacks received total", metrics => [{"mqtt.publisher.qos1.puback.in.total", counter}]}},
            {graph, #{title => "QoS 1: Outstanding Pubacks (Waiting Acks)", metrics => [{"mqtt.publisher.qos1.puback.waiting", counter}]}}
        ]},
        {group, "MQTT Publishers QoS 2", [
            % QoS 2 Publisher flow
            {graph, #{title => "QoS 2: Publish to Pubrec_in latency", metrics => [{"mqtt.publisher.qos2.pub_out_to_pubrec_in.latency", histogram}]}},
            {graph, #{title => "QoS 2: Pubrecs received total", metrics => [{"mqtt.publisher.qos2.pubrec.in.total", counter}]}},
            {graph, #{
                title => "QoS 2: Pubrec_in to Pubrel_out internal latency",
                metrics => [{"mqtt.publisher.qos2.pubrec_in_to_pubrel_out.internal_latency", histogram}]
            }},
            {graph, #{
                title => "QoS 2: Pubrel_out to Pubcomp_in latency",
                metrics => [{"mqtt.publisher.qos2.pubrel_out_to_pubcomp_in.latency", histogram}]
            }},
            {graph, #{title => "QoS 2: Outstanding Pubrecs (Waiting Acks)", metrics => [{"mqtt.publisher.qos2.pubrec.waiting", counter}]}},
            {graph, #{title => "QoS 2: Outstanding Pubcomps (Waiting Acks)", metrics => [{"mqtt.publisher.qos2.pubcomp.waiting", counter}]}}
        ]},
        {group, "MQTT Connections", [
            {graph, #{title => "Connack Latency", metrics => [{"mqtt.connection.connack.latency", histogram}]}},
            {graph, #{title => "Total Connections", metrics => [{"mqtt.connection.current_total", counter}]}},
            {graph, #{title => "Connection errors", metrics => [{"mqtt.connection.connect.errors", histogram}]}},
            {graph, #{title => "Reconnects", metrics => [{"mqtt.connection.reconnects", counter}]}}
        ]},
        {group, "MQTT Messages", [
            {graph, #{title => "Total published messages", metrics => [{"mqtt.message.published.total", counter}]}},
            {graph, #{title => "Total consumed messages", metrics => [{"mqtt.message.consumed.total", counter}]}}
        ]},
        {group, "MQTT Consumers", [
            {graph, #{title => "Suback Latency", metrics => [{"mqtt.consumer.suback.latency", histogram}]}},
            {graph, #{title => "Unsuback Latency", metrics => [{"mqtt.consumer.unsuback.latency", histogram}]}},
            {graph, #{title => "Consumer Total", metrics => [{"mqtt.consumer.current_total", counter}]}},
            {graph, #{title => "Consumer Suback Errors", metrics => [{"mqtt.consumer.suback.errors", counter}]}},
            % QoS 1 consumer flow
            {graph, #{
                title => "QoS 1: Publish_in to Puback_out internal latency",
                metrics => [{"mqtt.consumer.qos1.publish_in_to_puback_out.internal_latency", histogram}]
            }},
            % QoS 2 consumer flow
            {graph, #{
                title => "QoS 2: Publish_in to Pubrec_out internal latency",
                metrics => [{"mqtt.consumer.qos2.publish_in_to_pubrec_out.internal_latency", histogram}]
            }},
            {graph, #{
                title => "QoS 2: Pubrec_out to Pubrel_in latency",
                metrics => [{"mqtt.consumer.qos2.pubrec_out_to_pubrel_in.latency", histogram}]
            }},
            {graph, #{
                title => "QoS 2: Pubrel_in to Pubcomp_out internal latency",
                metrics => [{"mqtt.consumer.qos2.pubrel_in_to_pubcomp_out.internal_latency", histogram}]
            }}
        ]}
    ].

-spec set_prefix(gkstate(), meta(), string()) -> {nil, gkstate()}.
set_prefix(State, _Meta, NewPrefix) ->
    mzb_metrics:declare_metrics(metrics(NewPrefix)),
    {nil, State#gkstate{prefix = NewPrefix}}.

-spec gk_disconnect(gkstate(), meta()) -> {nil, gkstate()}.
gk_disconnect(#gkstate{gk_connection = GK_connection} = State, _Meta) ->
    hackney:close(GK_connection),
    {nil, State}.

-spec gk_connect(gkstate(), meta(), string() | binary(), integer()) -> {nil, gkstate()}.
gk_connect(State, Meta, Host, Port) when is_list(Host) ->
    gk_connect(State, Meta, list_to_binary(Host), Port);
gk_connect(State, _Meta, Host, Port) ->
    {ok, ConnRef} = hackney:connect(hackney_ssl, Host, Port, []),
    {nil, State#gkstate{gk_connection = ConnRef}}.

-spec set_options(gkstate(), meta(), http_options()) -> {nil, gkstate()}.
set_options(State, _Meta, NewOptions) ->
    {nil, State#gkstate{http_options = NewOptions}}.

-spec get(gkstate(), meta(), string() | binary()) -> {nil, gkstate()}.
get(State, Meta, Endpoint) when is_list(Endpoint) ->
    get(State, Meta, list_to_binary(Endpoint));
get(#gkstate{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint) ->
    Response = ?TIMED(Prefix ++ ".http_latency", hackney:send_request(GK_connection,
        {get, Endpoint, Options, <<>>})),
    {nil, State#gkstate{gk_connection = record_response(Prefix, Response)}}.

-spec gk_post(gkstate(), meta(), string() | binary(), iodata()) -> {nil, gkstate()}.
gk_post(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    gk_post(State, Meta, list_to_binary(Endpoint), Payload);
gk_post(#gkstate{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".http_latency", hackney:send_request(GK_connection,
        {post, Endpoint, Options, Payload})),
    { hackney:body(GK_connection), State#gkstate{gk_connection = record_response(Prefix, Response)}}.

-spec mns_register(gkstate(), meta(), string(), integer()) -> {nil,gkstate()}.
mns_register(#gkstate{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, Meta, Endpoint, MacPrefix) ->
    GKHeaders = [{<<"Content-Type">>, <<"application/json">>}],
    StringMacPrefix = integer_to_list(MacPrefix),
    FinalMacPrefix = re:replace(StringMacPrefix,"[0-9]{2}", "&:", [global, {return, list}]),
    JsonOutput = io_lib:format("{\"radar_status\": {\"deviceId\": \"test-~s\", \"ts\": 0.0, \"interfaces\": [{\"name\": \"wan0\", \"type\": \"ETHERNET\", \"mac\": \"~s01\", \"ip\": \"10.22.22.1\", \"routes\": [{\"dst\": \"0.0.0.0\"}]}], \"links\": [{\"mac\": \"~s10\", \"peer_type\": \"7\"}, {\"mac\": \"~s20\", \"peer_type\": \"7\"}, {\"mac\": \"~s30\", \"peer_type\": \"2\"}], \"ap_bssid_2ghz\": \"~s02\", \"ap_bssid_5ghz\": \"~s:03\", \"mesh_bssid\": \"~s:00\", \"gateway_bssid\": \"ff:00:00:00:00:00\", \"root_mode\": 2}, \"factory_reset\": \"False\", \"master_failed\": \"False\", \"location_id\": \"~s:00\"}", [StringMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix, FinalMacPrefix]),
    %gk_connect( #gkstate{gk_connection = GK_connection} = State, Meta,"mns.load.qa.wifimotion.ca", 443),
    set_options(GK_connection, Meta, GKHeaders),
    %Payload = <<"potato">>,
    Path = <<"/gatekeeper">>,
    {{ok,ResponseBody}, OtherState} = gk_post(State, Meta, Path,  JsonOutput),
    MQUsername = <<"device">>,
    {match,NetworkId}=re:run(ResponseBody, "network_id\":([0-9]*)", [{capture, all_but_first, list}]),
    {match,GuardianId}=re:run(ResponseBody, "guardian_mqtt.*guardian_id\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {match,MQServer}=re:run(ResponseBody, "guardian_mqtt.*mqServer\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {match,MQPassword}=re:run(ResponseBody, "guardian_mqtt.*mqToken\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {nil, GK_connection}.
    

    %lager:error("MNS: NetworkId: ~s GuardianID: ~s MQServer: ~s MQQPassword: ~s ----------all Else ~s", [NetworkId, GuardianId, MQServer, MQPassword, ResponseBody]).

-spec put(gkstate(), meta(), string() | binary(), iodata()) -> {nil, gkstate()}.
put(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    put(State, Meta, list_to_binary(Endpoint), Payload);
put(#gkstate{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".http_latency", hackney:send_request(GK_connection,
        {put, Endpoint, Options, Payload})),
    {nil, State#gkstate{gk_connection = record_response(Prefix, Response)}}.

record_response(Prefix, Response) ->
    case Response of
        {ok, 200, _, GK_connection} ->
            %{ok, Body} = hackney:body(GK_connection),
            mzb_metrics:notify({Prefix ++ ".http_ok", counter}, 1),
            GK_connection;
        {ok, _, _, GK_connection} ->
            %{ok, Body} = hackney:body(GK_connection),
            %lager:error("hackney:response fail: ~p", [Body]),
            mzb_metrics:notify({Prefix ++ ".http_fail", counter}, 1),
            GK_connection;
        E ->
            lager:error("hackney:request failed: ~p", [E]),
            mzb_metrics:notify({Prefix ++ ".other_fail", counter}, 1)
    end.













%% ------------------------------------------------
%% Gen_MQTT Callbacks (partly un-used)
%% ------------------------------------------------
on_connect(State) ->
    mzb_metrics:notify({"mqtt.connection.current_total", counter}, 1),
    {ok, State}.

on_connect_error(_Reason, State) ->
    mzb_metrics:notify({"mqtt.connection.connect.errors", counter}, 1),
    {ok, State}.

on_disconnect(State) ->
    mzb_metrics:notify({"mqtt.connection.current_total", counter}, -1),
    {ok, State}.

on_subscribe(Topics, State) ->
    case Topics of
        {error, _T, _QoSTable} ->
            mzb_metrics:notify({"mqtt.consumer.suback.errors", counter}, 1);
    _ ->
    mzb_metrics:notify({"mqtt.consumer.current_total", counter}, 1)
    end,
    {ok, State}.

on_unsubscribe(_Topics, State) ->
    mzb_metrics:notify({"mqtt.consumer.current_total", counter}, -1),
    {ok, State}.

on_publish(Topic, Payload, #mqtt{action=Action} = State) ->
    mzb_metrics:notify({"mqtt.message.consumed.total", counter}, 1),
    case Action of
        {forward, TopicPrefix, Qos} ->
            {_Timestamp, OrigPayload} = binary_to_term(Payload),
            ClientId = binary_to_list(lists:last(Topic)),
            case vmq_topic:validate_topic(publish, list_to_binary(TopicPrefix ++ ClientId)) of
                {ok, OutTopic} ->
                    NewPayload = term_to_binary({os:timestamp(), OrigPayload}),
                    gen_emqtt:publish(self(), OutTopic, NewPayload, Qos, false),
                    mzb_metrics:notify({"mqtt.message.published.total", counter}, 1),
                    {ok, State};
                {error, Reason} ->
                    error_logger:warning_msg("Can't validate topic ~p due to ~p~n", [Topic, Reason]),
                    {ok, State}
            end;
        {idle} ->
            {ok, State}
    end.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(Req, State) ->
    {noreply, State#mqtt{action=Req}}.

handle_info(_Req, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    mzb_metrics:notify({"mqtt.connection.current_total", counter}, -1),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------
%% MZBench API (Statement Functions)
%% ------------------------------------------------

connect(State, _Meta, ConnectOpts) ->
    ClientId = proplists:get_value(client, ConnectOpts),
    lager:warning("The client ID ~p and state: ~p <<", [ClientId, State]),
    Args = #mqtt{action={idle}},
    {ok, SessionPid} = gen_emqtt:start_link(?MODULE, Args, [{info_fun, {fun stats/2, maps:new()}}|ConnectOpts]),
    {nil, State#state{mqtt_fsm=SessionPid, client=ClientId}}.

disconnect(#state{mqtt_fsm=SessionPid} = State, _Meta) ->
    gen_emqtt:disconnect(SessionPid),
    {nil, State}.

publish(State, _Meta, Topic, Payload, QoS) ->
    publish(State, _Meta, Topic, Payload, QoS, false).

publish(#state{mqtt_fsm = SessionPid} = State, _Meta, Topic, Payload, QoS, Retain) ->
    case vmq_topic:validate_topic(publish, list_to_binary(Topic)) of
        {ok, TTopic} ->
            Payload1 = term_to_binary({os:timestamp(), Payload}),
            gen_emqtt:publish(SessionPid, TTopic, Payload1, QoS, Retain),
            mzb_metrics:notify({"mqtt.message.published.total", counter}, 1),
            {nil, State};
        {error, Reason} ->
            error_logger:warning_msg("Can't validate topic ~p due to ~p~n", [Topic, Reason]),
            {nil, State}
    end.


subscribe(#state{mqtt_fsm = SessionPid} = State, _Meta, [T|_] = Topics) when is_tuple(T) ->
    ValidTopics = lists:filtermap(
        fun({Topic, Qos}) ->
            case vmq_topic:validate_topic(subscribe, list_to_binary(Topic)) of
                {ok, ValidTopic} ->
                    {true, {ValidTopic, Qos}};
                {error, Reason} ->
                    error_logger:warning_msg("Can't validate topic conf ~p due to ~p~n", [Topic, Reason]),
                    false
            end
        end,
        Topics
    ),
    gen_emqtt:subscribe(SessionPid, ValidTopics),
    {nil, State}.

subscribe(State, Meta, Topic, Qos) ->
    subscribe(State, Meta, [{Topic, Qos}]).

unsubscribe(#state{mqtt_fsm = SessionPid} = State, _Meta, Topics) ->
    gen_emqtt:unsubscribe(SessionPid, Topics),
    {nil, State}.

subscribe_to_self(#state{client = ClientId} = State, _Meta, TopicPrefix, Qos) ->
    subscribe(State, _Meta, TopicPrefix ++ ClientId, Qos).

publish_to_self(#state{client = ClientId} = State, _Meta, TopicPrefix, Payload, Qos) ->
    publish(State, _Meta, TopicPrefix ++ ClientId, Payload, Qos).

publish_to_one(State, Meta, TopicPrefix, ClientId, Payload, Qos) ->
    publish_to_one(State, Meta, TopicPrefix, ClientId, Payload, Qos, false).

publish_to_one(State, Meta, TopicPrefix, ClientId, Payload, Qos, Retain) ->
    publish(State, Meta, TopicPrefix ++ ClientId, Payload, Qos, Retain).

idle(#state{mqtt_fsm = SessionPid} = State, _Meta) ->
    gen_fsm:send_all_state_event(SessionPid, {idle}),
    {nil, State}.

forward(#state{mqtt_fsm = SessionPid} = State, _Meta, TopicPrefix, Qos) ->
    gen_fsm:send_all_state_event(SessionPid, {forward, TopicPrefix, Qos}),
    {nil, State}.

client(#state{client = Client}=State, _Meta) ->
    {Client, State}.

worker_id(State, Meta) ->
    ID = proplists:get_value(worker_id, Meta),
    {ID, State}.

fixed_client_id(State, _Meta, Name, Id) -> {[Name, "-", integer_to_list(Id)], State}.

random_client_id(State, _Meta, N) ->
    {randlist(N) ++ pid_to_list(self()), State}.

random_client_ip(State, _Meta, IfPrefix) ->
    {ok, Interfaces} = inet:getifaddrs(),
    IfConfigurations = [Conf || {IfName, Conf} <- Interfaces, lists:prefix(IfPrefix, IfName)],
    Addresses = [Ip || {addr, Ip} <- lists:flatten(IfConfigurations), tuple_size(Ip) == 4],
    case length(Addresses) of
        0 ->
            {"0.0.0.0", State};
        Total ->
            {lists:nth(random:uniform(Total), Addresses), State}
    end.

load_client_cert(State, _Meta, CertBin) ->
    Pems = public_key:pem_decode(CertBin),
    {value, Certificate} = lists:keysearch('Certificate', 1, Pems),
    PKey = get_cert_bin(Certificate),
    {PKey, State}.

load_client_key(State, _Meta, KeyBin) ->
    [{'RSAPrivateKey', KB, _}] = public_key:pem_decode(KeyBin),
    {{'RSAPrivateKey', KB}, State}.

load_cas(State, _Meta, CABin) ->
    CAList = public_key:pem_decode(CABin),
    CL = [get_cert_bin(Key) || Key <- CAList],
    {CL, State}.

get_cert_bin(Cert) ->
    {'Certificate', CertBin, _} = Cert,
    CertBin.

%% ------------------------------------------------
%% Gen_MQTT Info Callbacks
%% ------------------------------------------------

stats({connect_out, ClientId}, State) -> % log connection attempt
    io:format("connect_out for client_id: ~p~n", [ClientId]),
    T1 = os:timestamp(),
    maps:put(ClientId, T1, State);
stats({connack_in, ClientId}, State) ->
    diff(ClientId, State, "mqtt.connection.connack.latency", histogram);
stats({reconnect, _ClientId}, State) ->
    mzb_metrics:notify({"mqtt.connection.reconnects", counter}, 1),
    State;
stats({publish_out, MsgId, QoS}, State)  ->
    case QoS of
        0 -> ok;
        1 -> mzb_metrics:notify({"mqtt.publisher.qos1.puback.waiting", counter}, 1);
        2 -> mzb_metrics:notify({"mqtt.publisher.qos2.pubrec.waiting", counter}, 1)
    end,
    maps:put({outgoing, MsgId}, os:timestamp(), State);
stats({publish_in, MsgId, Payload, QoS}, State) ->
    T2 = os:timestamp(),
    {T1, _OldPayload} = binary_to_term(Payload),
    Diff = positive(timer:now_diff(T2, T1)),
    case QoS of
        0 -> mzb_metrics:notify({"mqtt.message.pub_to_sub.latency", histogram}, Diff);
        1 -> mzb_metrics:notify({"mqtt.message.pub_to_sub.latency.qos1", histogram}, Diff);
        2 -> mzb_metrics:notify({"mqtt.message.pub_to_sub.latency.qos2", histogram}, Diff)
    end,
    maps:put({incoming, MsgId}, T2, State);
stats({puback_in, MsgId}, State) ->
    T1 = maps:get({outgoing, MsgId}, State),
    T2 = os:timestamp(),
    mzb_metrics:notify({"mqtt.publisher.qos1.puback.latency", histogram}, positive(timer:now_diff(T2, T1))),
    mzb_metrics:notify({"mqtt.publisher.qos1.puback.in.total", counter}, 1),
    mzb_metrics:notify({"mqtt.publisher.qos1.puback.waiting", counter}, -1),
    NewState = maps:remove({outgoing, MsgId}, State),
    NewState;
stats({puback_out, MsgId}, State) ->
    diff({incoming, MsgId}, State, "mqtt.consumer.qos1.publish_in_to_puback_out.internal_latency", histogram);
stats({suback, MsgId}, State) ->
    diff(MsgId, State, "mqtt.consumer.suback.latency", histogram);
stats({subscribe_out, MsgId}, State) ->
    T1 = os:timestamp(),
    maps:put(MsgId, T1, State);
stats({unsubscribe_out, MsgId}, State) ->
    T1 = os:timestamp(),
    maps:put(MsgId, T1, State);
stats({unsuback, MsgId}, State) ->
    diff(MsgId, State, "mqtt.consumer.unsuback.latency", histogram);
stats({pubrec_in, MsgId}, State) ->
    T2 = os:timestamp(),
    T1 = maps:get({outgoing, MsgId}, State),
    mzb_metrics:notify({"mqtt.publisher.qos2.pub_out_to_pubrec_in.latency", histogram}, positive(timer:now_diff(T2, T1))),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrec.in.total"}, 1),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrec.waiting", counter}, -1),
    NewState = maps:update({outgoing, MsgId}, T2, State),
    NewState;
stats({pubrec_out, MsgId}, State) ->
    T2 = maps:get({incoming, MsgId}, State),
    T3 = os:timestamp(),
    mzb_metrics:notify({"mqtt.consumer.qos2.publish_in_to_pubrec_out.internal_latency", histogram}, positive(timer:now_diff(T3, T2))),
    NewState = maps:update({incoming, MsgId}, T3, State),
    NewState;
stats({pubrel_out, MsgId}, State) ->
    T3 = os:timestamp(),
    T2 = maps:get({outgoing, MsgId}, State),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrec_in_to_pubrel_out.internal_latency", histogram}, positive(timer:now_diff(T3, T2))),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubcomp.waiting", counter}, 1),
    NewState = maps:update({outgoing, MsgId}, T3, State),
    NewState;
stats({pubrel_in, MsgId}, State) ->
    T4 = os:timestamp(),
    T3 = maps:get({incoming, MsgId}, State),
    mzb_metrics:notify({"mqtt.consumer.qos2.pubrec_out_to_pubrel_in.latency", histogram}, positive(timer:now_diff(T4, T3))),
    NewState = maps:update({incoming, MsgId}, T4, State),
    NewState;
stats({pubcomp_in, MsgId}, State) ->
    T4 = os:timestamp(),
    T3 = maps:get({outgoing, MsgId}, State),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubrel_out_to_pubcomp_in.latency", histogram}, positive(timer:now_diff(T4, T3))),
    mzb_metrics:notify({"mqtt.publisher.qos2.pubcomp.waiting", counter}, -1),
    NewState = maps:remove({outgoing, MsgId}, State),
    NewState;
stats({pubcomp_out, MsgId}, State) ->
    T5 = os:timestamp(),
    T4 = maps:get({incoming, MsgId}, State),
    mzb_metrics:notify({"mqtt.consumer.qos2.pubrel_in_to_pubcomp_out.internal_latency", histogram}, positive(timer:now_diff(T5, T4))),
    NewState = maps:remove({incoming, MsgId}, State),
    NewState.

diff(MsgId, State, Metric, MetricType) ->
    T2 = os:timestamp(),
    T1 = maps:get(MsgId, State),
    mzb_metrics:notify({Metric, MetricType}, positive(timer:now_diff(T2, T1))),
    NewState = maps:remove(MsgId, State),
    NewState.

positive(Val) when Val < 0 -> 0;
positive(Val) when Val >= 0 -> Val.

randlist(N) ->
    randlist(N, []).
randlist(0, Acc) ->
    Acc;
randlist(N, Acc) ->
    randlist(N - 1, [random:uniform(26) + 96 | Acc]).