-module(mns_worker).

-export([initial_state/0, metrics/0]).

-export([gk_connect/4, set_options/3, gk_disconnect/2,
    get/3, gk_post/4, put/4, set_prefix/3, mns_register/4]).

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
    #gkstate{}.

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
    set_options(State, Meta, GKHeaders),
    %Payload = <<"potato">>,
    Path = <<"/gatekeeper">>,
    {{ok,ResponseBody}, OtherState} = gk_post(State, Meta, Path,  JsonOutput),
    {match,NetworkId}=re:run(ResponseBody, "network_id\":([0-9]*)", [{capture, all_but_first, list}]),
    {match,GuardianId}=re:run(ResponseBody, "guardian_mqtt.*guardian_id\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {match,MQServer}=re:run(ResponseBody, "guardian_mqtt.*mqServer\":\"([^\"]*)", [{capture, all_but_first, list}]),
    {match,MQPassword}=re:run(ResponseBody, "guardian_mqtt.*mqToken\":\"([^\"]*)", [{capture, all_but_first, list}]),
    MQUsername = "device",

    lager:error("MNS: NetworkId: ~s GuardianID: ~s MQServer: ~s MQQPassword: ~s ----------all Else ~s", [NetworkId, GuardianId, MQServer, MQPassword, ResponseBody]).

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

