-module(mns_worker).

-export([initial_state/0, metrics/0]).

-export([gk_connect/4, set_options/3, gk_disconnect/2,
    get/3, gk_post/4, put/4, set_prefix/3]).

-type meta() :: [{Key :: atom(), Value :: any()}].
-type http_options() :: list().

-record(state,
    { gk_connection = undefined
    , prefix = "default"
    , http_options = [] :: http_options()
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

-spec gk_disconnect(state(), meta()) -> {nil, state()}.
gk_disconnect(#state{gk_connection = GK_connection} = State, _Meta) ->
    hackney:close(GK_connection),
    {nil, State}.

-spec gk_connect(state(), meta(), string() | binary(), integer()) -> {nil, state()}.
gk_connect(State, Meta, Host, Port) when is_list(Host) ->
    gk_connect(State, Meta, list_to_binary(Host), Port);
gk_connect(State, _Meta, Host, Port) ->
    {ok, ConnRef} = hackney:connect(hackney_ssl, Host, Port, []),
    {nil, State#state{gk_connection = ConnRef}}.

-spec set_options(state(), meta(), http_options()) -> {nil, state()}.
set_options(State, _Meta, NewOptions) ->
    {nil, State#state{http_options = NewOptions}}.

-spec get(state(), meta(), string() | binary()) -> {nil, state()}.
get(State, Meta, Endpoint) when is_list(Endpoint) ->
    get(State, Meta, list_to_binary(Endpoint));
get(#state{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint) ->
    Response = ?TIMED(Prefix ++ ".latency", hackney:send_request(GK_connection,
        {get, Endpoint, Options, <<>>})),
    {nil, State#state{gk_connection = record_response(Prefix, Response)}}.

-spec gk_post(state(), meta(), string() | binary(), iodata()) -> {nil, state()}.
gk_post(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    gk_post(State, Meta, list_to_binary(Endpoint), Payload);
gk_post(#state{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".latency", hackney:send_request(GK_connection,
        {post, Endpoint, Options, Payload})),
    { hackney:body(GK_connection), State#state{gk_connection = record_response(Prefix, Response)}}.

-spec put(state(), meta(), string() | binary(), iodata()) -> {nil, state()}.
put(State, Meta, Endpoint, Payload) when is_list(Endpoint) ->
    put(State, Meta, list_to_binary(Endpoint), Payload);
put(#state{gk_connection = GK_connection, prefix = Prefix, http_options = Options} = State, _Meta, Endpoint, Payload) ->
    Response = ?TIMED(Prefix ++ ".latency", hackney:send_request(GK_connection,
        {put, Endpoint, Options, Payload})),
    {nil, State#state{gk_connection = record_response(Prefix, Response)}}.

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

