-module(cognitivesystems_worker).

-export([initial_state/0, metrics/0]).

-export([gatekeeper_connect/4, set_options/3, disconnect/2,
    get/3, post/4, put/4, set_prefix/3]).

-type meta() :: [{Key :: atom(), Value :: any()}].
-type http_options() :: list().

-record(state,
    { gatekeeper_connection = undefined
    , prefix = "default"
    , options = [] :: http_options()
    }).

-type state() :: #state{}.

-define(TIMED(Name, Expr),
    (fun () ->
        StartTime = os:timestamp(),
        Result = Expr,
        Value = timer:now_diff(os:timestamp(), StartTime),
        mzb_metrics:notify({Name, histogram}, Value),
        Result
    end)()).

-spec initial_state() -> state().
initial_state() ->
    application:set_env(hackney, use_default_pool, false),
    #state{}.

-spec metrics() -> list().
metrics() -> metrics("default").

metrics(Prefix) ->
    [
        {group, "HTTP (" ++ Prefix ++ ")", [
            {graph, #{title => "HTTP Response",
                      units => "N",
                      metrics => [{Prefix ++ ".http_ok", counter}, {Prefix ++ ".http_fail", counter}, {Prefix ++ ".other_fail", counter}]}},
            {graph, #{title => "Latency",
                      units => "microseconds",
                      metrics => [{Prefix ++ ".latency", histogram}]}}
        ]}
    ].

-spec set_prefix(state(), meta(), string()) -> {nil, state()}.
set_prefix(State, _Meta, NewPrefix) ->
    mzb_metrics:declare_metrics(metrics(NewPrefix)),
    {nil, State#state{prefix = NewPrefix}}.

-spec disconnect(state(), meta()) -> {nil, state()}.
disconnect(#state{gatekeeper_connection = Connection} = State, _Meta) ->
    hackney:close(Connection),
    {nil, State}.

-spec gatekeeper_connect(state(), meta(), string() | binary(), integer()) -> {nil, state()}.
gatekeeper_connect(State, Meta, Host, Port) when is_list(Host) ->
    gatekeeper_connect(State, Meta, list_to_binary(Host), Port);
gatekeeper_connect(State, _Meta, Host, Port) ->
    {ok, ConnRef} = hackney:connect(hackney_ssl, Host, Port, []),
    {nil, State#state{gatekeeper_connection = ConnRef}}.

-spec set_options(state(), meta(), http_options()) -> {nil, state()}.
set_options(State, _Meta, NewOptions) ->
    {nil, State#state{options = NewOptions}}.

-spec get(state(), meta(), string() | binary()) -> {nil, state()}.
get(State, Meta, Endpoint) when is_list(Endpoint) ->
    get(State, Meta, list_to_binary(Endpoint));
get(#state{gatekeeper_connection = Connection, prefix = Prefix, options = Options} = State, _Meta, Endpoint) ->
    Response = ?TIMED(Prefix ++ ".latency", hackney:send_request(Connection,
        {get, Endpoint, Options, <<>>})),
    {nil, State#state{gatekeeper_connection = record_response(Prefix, Response)}}.

-spec post(state(), meta(), string() | binary(), iodata()) -> {nil, state()}.
post(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    post(State, Meta, list_to_binary(Endpoint), Payload);
post(#state{gatekeeper_connection = Connection, prefix = Prefix, options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".latency", hackney:send_request(Connection,
        {post, Endpoint, Options, Payload})),
    { hackney:body(Connection), State#state{gatekeeper_connection = record_response(Prefix, Response)}}.

-spec put(state(), meta(), string() | binary(), iodata()) -> {nil, state()}.
put(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    put(State, Meta, list_to_binary(Endpoint), Payload);
put(#state{gatekeeper_connection = Connection, prefix = Prefix, options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".latency", hackney:send_request(Connection,
        {put, Endpoint, Options, Payload})),
    {nil, State#state{gatekeeper_connection = record_response(Prefix, Response)}}.

record_response(Prefix, Response) ->
    case Response of
        {ok, 200, _, Connection} ->
            %{ok, Body} = hackney:body(Connection),
            mzb_metrics:notify({Prefix ++ ".http_ok", counter}, 1),
            Connection;
        {ok, _, _, Connection} ->
            %{ok, Body} = hackney:body(Connection),
            %lager:error("hackney:response fail: ~p", [Body]),
            mzb_metrics:notify({Prefix ++ ".http_fail", counter}, 1),
            Connection;
        E ->
            lager:error("hackney:request failed: ~p", [E]),
            mzb_metrics:notify({Prefix ++ ".other_fail", counter}, 1)
    end.

