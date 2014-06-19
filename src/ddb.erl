-module(ddb).

-export([connection/4]).
-export([connection_local/0, connection_local/2]).

-export([create_table/4]).
-export([delete_item/4]).
-export([delete_table/2]).
-export([get_item/3]).
-export([get_item/4]).
-export([list_tables/1]).
-export([put_item/3]).
-export([update_item/5]).

-export_type([config/0]).

-include_lib("eunit/include/eunit.hrl").

-define(SERVICE, <<"dynamodb">>).

-record(ddb_config, {access_key_id :: binary(),
                     secret_access_key :: binary(),
                     is_secure = true :: boolean(),
                     endpoint :: binary(),
                     service :: binary(),
                     region :: binary(),

                     local = false :: boolean(),
                     host :: binary(),
                     port :: inet:port_number()}).

-type config() :: #ddb_config{}.


%% http://docs.aws.amazon.com/general/latest/gr/rande.html#ddb_region

%% XXX(nakai): サービスの扱いをどうするか考える

-spec connection(binary(), binary(), binary(), boolean()) -> #ddb_config{}.
connection(AccessKeyId, SecretAccessKey, Region, IsSecure) ->
    #ddb_config{access_key_id = AccessKeyId,
                secret_access_key = SecretAccessKey,
                region = Region,
                is_secure = IsSecure,
                service = ?SERVICE,
                endpoint = endpoint(?SERVICE, Region)}.


-spec endpoint(binary(), binary()) -> binary().
endpoint(Service, Region) ->
    <<Service/binary, $., Region/binary, $., "amazonaws.com">>.


connection_local() ->
    connection_local(<<"127.0.0.1">>, 8000).

connection_local(Host, Port) ->
    #ddb_config{host = Host,
                port = Port,
                access_key_id = <<"ACCESS_KEY_ID">>,
                secret_access_key = <<"SECRET_ACCESS_KEY">>,
                endpoint = <<Host/binary, $:, (integer_to_binary(Port))/binary>>,
                region = <<"ap-northeast-1">>,
                service = ?SERVICE,
                local = true,
                is_secure = false}.


-spec put_item(#ddb_config{}, binary(), [{binary(), binary()}]) -> ok.
put_item(Config, TableName, Item) ->
    Target = x_amz_target(put_item),
    Payload = put_item_payload(TableName, Item),
    case post(Config, Target, Payload) of
        {ok, _Json} ->
            ?debugVal(_Json),
            ok;
        {error, Reason} ->
            ?debugVal(Reason),
            {error, Reason}
    end.


put_item_payload(TableName, Item) ->
    F = fun({Name, Value}) when is_binary(Value) ->
                {Name, [{<<"S">>, Value}]};
           ({Name, Value}) when is_integer(Value) ->
                {Name, [{<<"N">>, integer_to_binary(Value)}]}
        end,
    Item1 = lists:map(F, Item),

    F1 = fun({Name, _Value}) ->
                 %% FIXME(nakai): 上書き禁止を固定している
                {Name, [{<<"Exists">>, false}]}
         end,
    Expected1 = lists:map(F1, Item),
    Json = [{<<"TableName">>, TableName},
            {<<"Expected">>, Expected1},
            {<<"Item">>, Item1}],
    jsonx:encode(Json).


-spec get_item(#ddb_config{}, binary(), binary(), binary()) -> not_found | [{binary(), binary()}].
get_item(Config, TableName, Key, Value) ->
    get_item(Config, TableName, [{Key, Value}]).

-spec get_item(#ddb_config{}, binary(), [{binary(), binary}]) -> not_found | [{binary(), binary()}].
get_item(Config, TableName, KeyValues) ->
    Target = x_amz_target(get_item),
    Payload = get_item_payload(TableName, KeyValues),
    case post(Config, Target, Payload) of
        {ok, []} ->
            not_found;
        {ok, Json} ->
            %% XXX(nakai): Item はあえて出している
            Item = proplists:get_value(<<"Item">>, Json),
            F = fun({AttributeName, [{<<"N">>, V}]}) ->
                        {AttributeName, binary_to_integer(V)};
                   ({AttributeName, [{_T, V}]}) ->
                        {AttributeName, V}
                end,
            lists:map(F, Item);
        {error, Reason} ->
            ?debugVal(Reason),
            error(Reason)
    end.


get_item_payload(TableName, KeyValues) ->
    %% http://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_GetItem.html
    F = fun({Name, Value}) when is_binary(Value) ->
               {Name, [{<<"S">>, Value}]};
           ({Name, Value}) when is_integer(Value) ->
               {Name, [{<<"N">>, Value}]}
       end,
    Json = [{<<"TableName">>, TableName},
            {<<"Key">>, lists:map(F, KeyValues)},
            {<<"ConsistentRead">>, true}],
    jsonx:encode(Json).


-spec list_tables(#ddb_config{}) -> [binary()].
list_tables(Config) ->
    Target = x_amz_target(list_tables),
    Payload = jsonx:encode({[]}),
    case post(Config, Target, Payload) of
        {ok, Json} ->
            ?debugVal(Json),
            proplists:get_value(<<"TableNames">>, Json);
        {error, Reason} ->
            ?debugVal(Reason),
            error(Reason)
    end.


create_table(Config, TableName, AttributeName, KeyType) ->
    Target = x_amz_target(create_table),
    Payload = create_table_payload(TableName, AttributeName, KeyType),
    case post(Config, Target, Payload) of
        {ok, _Json} ->
            ?debugVal(_Json),
            ok;
        {error, Reason} ->
            ?debugVal(Reason),
            error(Reason)
    end.

%% KeyType HASH RANGE
create_table_payload(TableName, AttributeName, KeyType) ->
    %% http://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_CreateTable.html
    Json = [{<<"TableName">>, TableName},
            {<<"AttributeDefinitions">>, [
                                          [{<<"AttributeName">>, AttributeName},
                                           {<<"AttributeType">>, <<"S">>}
                                          ]
                                         ]
            },
            {<<"ProvisionedThroughput">>, [{<<"ReadCapacityUnits">>, 1},
                                           {<<"WriteCapacityUnits">>, 1}
                                          ]
            },
            {<<"KeySchema">>, [
                               [{<<"AttributeName">>, AttributeName},
                                {<<"KeyType">>, KeyType}]
                              ]
            }
           ],
    jsonx:encode(Json).


delete_item(Config, TableName, Key, Value) ->
    Target = x_amz_target(delete_item),
    Payload = delete_item_payload(TableName, Key, Value),
    case post(Config, Target, Payload) of
        {ok, _Json} ->
            ?debugVal(_Json),
            ok;
        {error, Reason} ->
            ?debugVal(Reason),
            error(Reason)
    end.


%% FIXME(nakai): S/N しかない
delete_item_payload(TableName, Key, Value) when is_binary(Value) ->
    delete_item_payload(TableName, Key, <<"S">>, Value);
delete_item_payload(TableName, Key, Value) when is_binary(Value) ->
    delete_item_payload(TableName, Key, <<"N">>, Value).

delete_item_payload(TableName, Key, Type, Value) ->
    Json = [{<<"TableName">>, TableName},
            {<<"Key">>, [{Key, [{Type, Value}]}]}],
    jsonx:encode(Json).


delete_table(Config, TableName) ->
    Target = x_amz_target(delete_table),
    Payload = delete_table_payload(TableName),
    post(Config, Target, Payload).


delete_table_payload(TableName) ->
    Json = [{<<"TableName">>, TableName}],
    jsonx:encode(Json).


-spec update_item(#ddb_config{}, binary(), binary(), binary(), [{binary(), binary(), binary()}]) -> term().
update_item(Config, TableName, Key, Value, AttributeUpdates) ->
    Target = x_amz_target(update_item),
    Payload = update_item_payload(TableName, Key, Value, AttributeUpdates),
    case post(Config, Target, Payload) of
        {ok, _Json} ->
            ?debugVal(_Json),
            ok;
        {error, Reason} ->
            ?debugVal(Reason),
            error(Reason)
    end.


%% AttributeUpdates [{AttributeName, Action, Value}] 
update_item_payload(TableName, Key, Value, AttributeUpdates) when is_binary(Value) ->
    update_item_payload(TableName, Key, <<"S">>, Value, AttributeUpdates);
update_item_payload(TableName, Key, Value, AttributeUpdates) when is_integer(Value) ->
    update_item_payload(TableName, Key, <<"N">>, Value, AttributeUpdates).


update_item_payload(TableName, Key, Type, Value, AttributeUpdates) ->
    F = fun({AttributeName, Action, V}) when is_binary(V) ->
                {AttributeName, [{<<"Action">>, Action},
                                 {<<"Value">>, [{<<"S">>, V}]}]};
           ({AttributeName, Action, V}) when is_integer(V) ->
                {AttributeName, [{<<"Action">>, Action},
                                 {<<"Value">>, [{<<"N">>, integer_to_binary(V)}]}]}
        end,
    AttributeUpdates1 = lists:map(F, AttributeUpdates),
    Json = [{<<"TableName">>, TableName},
            {<<"Key">>, [{Key, [{Type, Value}]}]},
            {<<"AttributeUpdates">>, AttributeUpdates1}],
    jsonx:encode(Json).


-spec x_amz_target(atom()) -> binary().
x_amz_target(batch_get_item) ->
    error(not_implemented);
x_amz_target(batch_write_item) ->
    error(not_implemented);
x_amz_target(create_table) ->
    <<"DynamoDB_20120810.CreateTable">>;
x_amz_target(delete_item) ->
    <<"DynamoDB_20120810.DeleteItem">>;
x_amz_target(delete_table) ->
    <<"DynamoDB_20120810.DeleteTable">>;
x_amz_target(describe_table) ->
    error(not_implemented);
x_amz_target(get_item) ->
    <<"DynamoDB_20120810.GetItem">>;
x_amz_target(list_tables) ->
    <<"DynamoDB_20120810.ListTables">>;
x_amz_target(put_item) ->
    <<"DynamoDB_20120810.PutItem">>;
x_amz_target(query) ->
    error(not_implemented);
x_amz_target(scan) ->
    error(not_implemented);
x_amz_target(update_item) ->
    <<"DynamoDB_20120810.UpdateItem">>;
x_amz_target(update_table) ->
    error(not_implemented);
x_amz_target(_OperationName) ->
    error({not_implemented, _OperationName}).


url(true, Endpoint) ->
    <<"https://", Endpoint/binary>>;
url(false, Endpoint) ->
    <<"http://", Endpoint/binary>>.


post(#ddb_config{access_key_id = AccessKeyId,
                 secret_access_key = SecretAccessKey,
                 service = Service,
                 region = Region,
                 endpoint = Endpoint,
                 is_secure = IsSecure}, Target, Payload) ->
    Headers0 = [{<<"x-amz-target">>, Target}, 
                {<<"host">>, Endpoint}],
    DateTime = aws:iso_8601_basic_format(os:timestamp()),
    Headers = aws:signature_version_4_signing(DateTime, AccessKeyId, SecretAccessKey, Headers0,
                                              Payload, Service, Region),
    Headers1 = [{<<"accept-encoding">>, <<"identity">>},
                {<<"content-type">>, <<"application/x-amz-json-1.0">>}|Headers],

    Url = url(IsSecure, Endpoint),

    case hackney:post(Url, Headers1, Payload, [{pool, default}]) of
        {ok, 200, _RespHeaders, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            ?debugVal(Body),
            {ok, jsonx:decode(Body, [{format, proplist}])};
        {ok, _StatusCode, _RespHeaders, ClientRef} ->
            ?debugVal(_StatusCode),
            ?debugVal(_RespHeaders),
            {ok, Body} = hackney:body(ClientRef),
            Json = jsonx:decode(Body, [{format, proplist}]),
            Type = proplists:get_value(<<"__type">>, Json),
            Message = proplists:get_value(<<"Message">>, Json),
            {error, {Type, Message}}
    end.


-ifdef(TEST).

%% connection_test() ->
%% 
%%     AccessKeyId = list_to_binary(os:getenv("AWS_ACCESS_KEY_ID")),
%%     SecretAccessKey = list_to_binary(os:getenv("AWS_SECRET_ACCESS_KEY")),
%%     Region = <<"ap-northeast-1">>,
%%     IsSecure = true,
%% 
%%     application:start(crypto),
%%     application:start(asn1),
%%     application:start(public_key),
%%     application:start(ssl),
%%     application:start(mimetypes),
%%     application:start(hackney_lib),
%%     application:start(hackney),
%% 
%%     C = ddb:connection(AccessKeyId, SecretAccessKey, Region, IsSecure),
%%     ddb:put_item(C, <<"users">>, [{<<"user_id">>, <<"USER-ID">>},
%%                                   {<<"password">>, <<"PASSWORD">>},
%%                                   {<<"gender">>, <<"GENDER">>}]),
%%     ddb:update_item(C, <<"users">>, <<"user_id">>, <<"USER-ID">>, [{<<"gender">>, <<"PUT">>, <<"gender">>}]),
%%     ddb:get_item(C, <<"users">>, <<"user_id">>, <<"USER-ID">>),
%% 
%%     application:stop(crypto),
%%     application:stop(asn1),
%%     application:stop(public_key),
%%     application:stop(ssl),
%%     application:stop(mimetypes),
%%     application:stop(hackney_lib),
%%     application:stop(hackney),
%% 
%%     ok.



connection_local_test() ->
    application:start(crypto),
    application:start(asn1),
    application:start(public_key),
    application:start(ssl),
    application:start(mimetypes),
    application:start(hackney_lib),
    application:start(hackney),

    hackney:start(),

    C = ddb:connection_local(<<"localhost">>, 8000),
    ?assertEqual([], ddb:list_tables(C)),
    ?assertEqual(ok,
                 ddb:create_table(C, <<"users">>, <<"user_id">>, <<"HASH">>)),
    ?assertEqual(ok,
                 ddb:put_item(C, <<"users">>, [{<<"user_id">>, <<"USER-ID">>},
                                               {<<"password">>, <<"PASSWORD">>},
                                               {<<"gender">>, 1}])),
    ?assertMatch({error, {_, _}},
                 ddb:put_item(C, <<"users">>, [{<<"user_id">>, <<"USER-ID">>},
                                               {<<"password">>, <<"PASSWORD">>},
                                               {<<"gender">>, 1}])),
    ?assertEqual([{<<"gender">>, 1},
                  {<<"user_id">>, <<"USER-ID">>},
                  {<<"password">>, <<"PASSWORD">>}],
                 ddb:get_item(C, <<"users">>, <<"user_id">>, <<"USER-ID">>)),
    ?assertEqual(ok,
                 ddb:update_item(C, <<"users">>, <<"user_id">>, <<"USER-ID">>,
                                 [{<<"gender">>, <<"PUT">>, 0},
                                  {<<"password">>, <<"PUT">>, <<"PASS">>}])),
    ?assertEqual([{<<"gender">>, 0},
                  {<<"user_id">>, <<"USER-ID">>},
                  {<<"password">>, <<"PASS">>}],
                 ddb:get_item(C, <<"users">>, <<"user_id">>, <<"USER-ID">>)),
    ?assertEqual(ok,
                 ddb:delete_item(C, <<"users">>, <<"user_id">>, <<"USER-ID">>)),
    ?assertEqual(not_found,
                 ddb:get_item(C, <<"users">>, <<"user_id">>, <<"USER-ID">>)),
    ddb:delete_table(C, <<"users">>),

    hackney:stop(),

    application:stop(crypto),
    application:stop(asn1),
    application:stop(public_key),
    application:stop(ssl),
    application:stop(mimetypes),
    application:stop(hackney_lib),
    application:stop(hackney),


    ok.

-endif.
