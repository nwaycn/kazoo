%%%-------------------------------------------------------------------
%%% @copyright (C) 2013-2016, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Pierre Fenoll
%%%-------------------------------------------------------------------
-module(knm_tasks_listener).
-behaviour(gen_listener).

-export([start_link/0]).

-export([help_req/2]).

-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("knm.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).

-define(BINDINGS, [{'self', []}
                  ]).
-define(RESPONDERS, [{{?MODULE, 'help_req'}
                     ,[{<<"tasks">>, <<"help_req">>}]
                     }
                    ]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Starts the server
%%--------------------------------------------------------------------
-spec start_link() -> startlink_ret().
start_link() ->
    gen_listener:start_link(?SERVER
                           ,[{'bindings', ?BINDINGS}
                            ,{'responders', ?RESPONDERS}
                            ]
                           ,[]
                           ).

%%--------------------------------------------------------------------
%% @doc Declare jobs available
%%--------------------------------------------------------------------
-spec help_req(kz_json:object(), kz_proplist()) -> 'ok'.
help_req(JObj, _Props) ->
    'true' = kapi_tasks:help_req_v(JObj),
    Q = kz_json:get_value(<<"Server-ID">>, JObj),
    MessageId = kz_json:get_value(<<"Msg-ID">>, JObj),
    RespJObj =
        kz_json:from_list([{<<"Tasks-For">>, <<"number-management">>}
                          ,{<<"Tasks-Module">>, <<"knm_tasks">>}
                          ,{<<"Tasks">>, kz_json:from_list(available_tasks())}
                          ,{<<"Msg-ID">>, MessageId}
                           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                          ]),
    kapi_tasks:publish_help_resp(Q, RespJObj).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {'ok', #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({'gen_listener', {'created_queue', _QueueName}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener', {'is_consuming', _IsConsuming}}, State) ->
    {'noreply', State};
handle_cast(_Msg, State) ->
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------
handle_event(_JObj, _State) ->
    {'reply', []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    lager:debug("listener terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec available_tasks() -> kz_proplist().
available_tasks() ->
    [{<<"list">>, kz_json:from_list([{<<"description">>, <<"List all numbers in the system">>}
                                    ,{<<"mandatory">>, [
                                                       ]}
                                    ,{<<"optional">>, [<<"auth_by">>
                                                      ]}
                                    ])
     }

    ,{<<"assign_to">>, kz_json:from_list([{<<"description">>, <<"Bulk-assign numbers to the provided account">>}
                                         ,{<<"expected_content">>, <<"text/csv">>}
                                         ,{<<"mandatory">>, [<<"number">>
                                                            ,<<"account_id">>
                                                            ]}
                                         ,{<<"optional">>, [<<"auth_by">>
                                                           ]}
                                         ])
     }

    ,{<<"delete">>, kz_json:from_list([{<<"description">>, <<"Bulk-remove numbers">>}
                                      ,{<<"expected_content">>, <<"text/csv">>}
                                      ,{<<"mandatory">>, [<<"number">>
                                                         ]}
                                      ,{<<"optional">>, [<<"auth_by">>
                                                        ]}
                                      ])
     }

    ,{<<"reserve">>, kz_json:from_list([{<<"description">>, <<"Bulk-move numbers to reserved (adding if missing)">>}
                                       ,{<<"expected_content">>, <<"text/csv">>}
                                       ,{<<"mandatory">>, [<<"number">>
                                                          ,<<"account_id">>
                                                          ]}
                                       ,{<<"optional">>, [<<"auth_by">>
                                                         ]}
                                       ])
     }

    ,{<<"add">>, kz_json:from_list([{<<"description">>, <<"Bulk-create numbers">>}
                                   ,{<<"expected_content">>, <<"text/csv">>}
                                   ,{<<"mandatory">>, [<<"number">>
                                                      ,<<"account_id">>
                                                      ]}
                                   ,{<<"optional">>, [<<"auth_by">>
                                                     ,<<"module_name">>
                                                     ]}
                                   ])
     }
    ,{<<"update_features">>, kz_json:from_list([{<<"description">>, <<"Bulk-update features of numbers">>}
                                               ,{<<"expected_content">>, <<"text/csv">>}
                                               ,{<<"mandatory">>, [<<"number">>
                                                                  ]}
                                               ,{<<"optional">>, [<<"cnam.inbound">>
                                                                 ,<<"cnam.outbound">>
                                                                 ,<<"e911.street_address">>
                                                                      %%TODO: exhaustive list
                                                                 ]}
                                               ])
     }
    ].

%% End of Module.
