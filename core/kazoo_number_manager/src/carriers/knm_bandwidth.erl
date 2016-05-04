%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz INC
%%% @doc
%%%
%%% Handle client requests for phone_number documents
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(knm_bandwidth).

-behaviour(knm_gen_carrier).

-export([find_numbers/3]).
-export([acquire_number/1]).
-export([disconnect_number/1]).
-export([is_number_billable/1]).
-export([should_lookup_cnam/0]).

-include("knm.hrl").

-define(KNM_BW_CONFIG_CAT, <<(?KNM_CONFIG_CAT)/binary, ".bandwidth">>).

-define(BW_XML_PROLOG, "<?xml version=\"1.0\"?>").
-define(BW_XML_NAMESPACE
        ,[{'xmlns:xsi', "http://www.w3.org/2001/XMLSchema-instance"}
          ,{'xmlns:xsd', "http://www.w3.org/2001/XMLSchema"}
          ,{'xmlns', "http://www.bandwidth.com/api/"}
         ]).
-define(BW_NUMBER_URL
        ,kapps_config:get_string(?KNM_BW_CONFIG_CAT
                                  ,<<"numbers_api_url">>
                                  ,"https://api.bandwidth.com/public/v2/numbers.api"
                                 )
       ).

-define(BW_CDR_URL
        ,kapps_config:get_string(?KNM_BW_CONFIG_CAT
                                  ,<<"cdrs_api_url">>
                                  ,"https://api.bandwidth.com/api/public/v2/cdrs.api"
                                 )
       ).

-define(BW_DEBUG, kapps_config:get_is_true(?KNM_BW_CONFIG_CAT, <<"debug">>, 'false')).
-define(BW_DEBUG_FILE, "/tmp/bandwidth.com.xml").
-define(BW_DEBUG(Format, Args),
        _ = ?BW_DEBUG andalso
        file:write_file(?BW_DEBUG_FILE, io_lib:format(Format, Args), ['append'])
       ).

-define(IS_SANDBOX_PROVISIONING_TRUE,
        kapps_config:get_is_true(?KNM_BW_CONFIG_CAT, <<"sandbox_provisioning">>, 'true')).
-define(IS_PROVISIONING_ENABLED,
        kapps_config:get_is_true(?KNM_BW_CONFIG_CAT, <<"enable_provisioning">>, 'true')).
-define(BW_ORDER_NAME_PREFIX,
        kapps_config:get_string(?KNM_BW_CONFIG_CAT, <<"order_name_prefix">>, "Kazoo")).

-define(BW_ENDPOINTS, kapps_config:get(?KNM_BW_CONFIG_CAT, <<"endpoints">>)).
-define(BW_DEVELOPER_KEY, kapps_config:get_string(?KNM_BW_CONFIG_CAT, <<"developer_key">>, "")).


%%% API

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Query the Bandwidth.com system for a quanity of available numbers
%% in a rate center
%% @end
%%--------------------------------------------------------------------
-spec find_numbers(ne_binary(), pos_integer(), kz_proplist()) ->
                          {'ok', knm_number:knm_numbers()} |
                          {'error', any()}.
find_numbers(<<"+", Rest/binary>>, Quanity, Options) ->
    find_numbers(Rest, Quanity, Options);
find_numbers(<<"1", Rest/binary>>, Quanity, Options) ->
    find_numbers(Rest, Quanity, Options);
find_numbers(<<NPA:3/binary>>, Quanity, Options) ->
    Props = [{'areaCode', [kz_util:to_list(NPA)]}
             ,{'maxQuantity', [kz_util:to_list(Quanity)]}
            ],
    case make_numbers_request('areaCodeNumberSearch', Props) of
        {'error', _}=E -> E;
        {'ok', Xml} -> process_numbers_search_resp(Xml, Options)
    end;
find_numbers(Search, Quanity, Options) ->
    NpaNxx = binary:part(Search, 0, (case size(Search) of L when L < 6 -> L; _ -> 6 end)),
    Props = [{'npaNxx', [kz_util:to_list(NpaNxx)]}
             ,{'maxQuantity', [kz_util:to_list(Quanity)]}
            ],
    case make_numbers_request('npaNxxNumberSearch', Props) of
        {'error', _}=E -> E;
        {'ok', Xml} -> process_numbers_search_resp(Xml, Options)
    end.

-spec process_numbers_search_resp(xml_el(), kz_proplist()) ->
                                         {'ok', knm_number:knm_numbers()}.
process_numbers_search_resp(Xml, Options) ->
    TelephoneNumbers = "/numberSearchResponse/telephoneNumbers/telephoneNumber",
    AccountId = props:get_value(<<"account_id">>, Options),

    {'ok', [found_number_to_KNM(Number, AccountId)
            || Number <- xmerl_xpath:string(TelephoneNumbers, Xml)
           ]
    }.

-spec found_number_to_KNM(xml_el() | xml_els(), maybe(binary())) ->
                                 knm_number:knm_number().
found_number_to_KNM(Found, AccountId) ->
    JObj = number_search_response_to_json(Found),
    Num = kz_json:get_value(<<"e164">>, JObj),
    {'ok', PhoneNumber} =
        knm_phone_number:newly_found(Num, ?MODULE, AccountId, JObj),
    knm_number:set_phone_number(knm_number:new(), PhoneNumber).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Acquire a given number from the carrier
%% @end
%%--------------------------------------------------------------------
-spec acquire_number(knm_number:knm_number()) ->
                            knm_number:knm_number().
acquire_number(Number) ->
    Debug = ?IS_SANDBOX_PROVISIONING_TRUE,
    case ?IS_PROVISIONING_ENABLED of
        'false' when Debug ->
            lager:debug("allowing sandbox provisioning"),
            Number;
        'false' ->
            knm_errors:unspecified('provisioning_disabled', Number);
        'true' ->
            acquire_and_provision_number(Number)
    end.

-spec acquire_and_provision_number(knm_number:knm_number()) ->
                                          knm_number:knm_number().
acquire_and_provision_number(Number) ->
    PhoneNumber = knm_number:phone_number(Number),
    AuthBy = knm_phone_number:auth_by(PhoneNumber),
    AssignedTo = knm_phone_number:assigned_to(PhoneNumber),
    Id = kz_json:get_string_value(<<"number_id">>, knm_phone_number:carrier_data(PhoneNumber)),
    Hosts = case ?BW_ENDPOINTS of
                'undefined' -> [];
                Endpoint when is_binary(Endpoint) ->
                    [{'endPoints', [{'host', [kz_util:to_list(Endpoint)]}]}];
                Endpoints ->
                    [{'endPoints', [{'host', [kz_util:to_list(E)]} || E <- Endpoints]}]
            end,
    OrderName = lists:flatten([?BW_ORDER_NAME_PREFIX, "-", integer_to_list(kz_util:current_tstamp())]),
    AcquireFor = case kz_util:is_empty(AssignedTo) of
                     'true' -> "no_assigned_account";
                     'false' -> binary_to_list(AssignedTo)
                 end,
    Props = [{'orderName', [OrderName]}
             ,{'extRefID', [binary_to_list(AuthBy)]}
             ,{'numberIDs', [{'id', [Id]}]}
             ,{'subscriber', [kz_util:to_list(AcquireFor)]}
             | Hosts
            ],
    case make_numbers_request('basicNumberOrder', Props) of
        {'error', Error} ->
            knm_errors:by_carrier(?MODULE, Error, Number);
        {'ok', Xml} ->
            Response = xmerl_xpath:string("/numberOrderResponse/numberOrder", Xml),
            Data = number_order_response_to_json(Response),
            knm_number:set_phone_number(
              Number
              ,knm_phone_number:set_carrier_data(PhoneNumber, Data)
             )
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Release a number from the routing table
%% @end
%%--------------------------------------------------------------------
-spec disconnect_number(knm_number:knm_number()) ->
                               knm_number:knm_number().
disconnect_number(Number) -> Number.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec is_number_billable(knm_number:knm_number()) -> 'true'.
is_number_billable(_Number) -> 'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec should_lookup_cnam() -> 'true'.
should_lookup_cnam() -> 'true'.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Make a REST request to Bandwidth.com Numbers API to preform the
%% given verb (purchase, search, provision, ect).
%% @end
%%--------------------------------------------------------------------
-spec make_numbers_request(atom(), kz_proplist()) ->
                                  {'ok', any()} |
                                  {'error', any()}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
make_numbers_request('npaNxxNumberSearch', _Props) ->
    {Xml, _} = xmerl_scan:string(?BANDWIDTH_NPAN_RESPONSE),
    verify_response(Xml);
make_numbers_request('areaCodeNumberSearch', _Props) ->
    {Xml, _} = xmerl_scan:string(?BANDWIDTH_AREACODE_RESPONSE),
    verify_response(Xml).
-else.
make_numbers_request(Verb, Props) ->
    lager:debug("making ~s request to bandwidth.com ~s", [Verb, ?BW_NUMBER_URL]),
    Request = [{'developerKey', [?BW_DEVELOPER_KEY]}
               | Props
              ],
    Body = unicode:characters_to_binary(
             xmerl:export_simple([{Verb, ?BW_XML_NAMESPACE, Request}]
                                 ,'xmerl_xml'
                                 ,[{'prolog', ?BW_XML_PROLOG}]
                                )
            ),
    Headers = [{"Accept", "*/*"}
               ,{"User-Agent", ?KNM_USER_AGENT}
               ,{"X-BWC-IN-Control-Processing-Type", "process"}
               ,{"Content-Type", "text/xml"}
              ],
    HTTPOptions = [{'ssl', [{'verify', 'verify_none'}]}
                   ,{'timeout', 180 * ?MILLISECONDS_IN_SECOND}
                   ,{'connect_timeout', 180 * ?MILLISECONDS_IN_SECOND}
                  , {'body_format', 'string'}
                  ],
    ?BW_DEBUG("Request:~n~s ~s~n~s~n", ['post', ?BW_NUMBER_URL, Body]),
    case kz_http:post(?BW_NUMBER_URL, Headers, Body, HTTPOptions) of
        {'ok', 401, _, _Response} ->
            ?BW_DEBUG("Response:~n401~n~s~n", [_Response]),
            lager:debug("bandwidth.com request error: 401 (unauthenticated)"),
            {'error', 'authentication'};
        {'ok', 403, _, _Response} ->
            ?BW_DEBUG("Response:~n403~n~s~n", [_Response]),
            lager:debug("bandwidth.com request error: 403 (unauthorized)"),
            {'error', 'authorization'};
        {'ok', 404, _, _Response} ->
            ?BW_DEBUG("Response:~n404~n~s~n", [_Response]),
            lager:debug("bandwidth.com request error: 404 (not found)"),
            {'error', 'not_found'};
        {'ok', 500, _, _Response} ->
            ?BW_DEBUG("Response:~n500~n~s~n", [_Response]),
            lager:debug("bandwidth.com request error: 500 (server error)"),
            {'error', 'server_error'};
        {'ok', 503, _, _Response} ->
            ?BW_DEBUG("Response:~n503~n~s~n", [_Response]),
            lager:debug("bandwidth.com request error: 503"),
            {'error', 'server_error'};
        {'ok', Code, _, "<?xml"++_=Response} ->
            ?BW_DEBUG("Response:~n~p~n~s~n", [Code, Response]),
            lager:debug("received response from bandwidth.com"),
            try
                {Xml, _} = xmerl_scan:string(Response),
                verify_response(Xml)
            catch
                _:R ->
                    lager:debug("failed to decode xml: ~p", [R]),
                    {'error', 'empty_response'}
            end;
        {'ok', Code, _, _Response} ->
            ?BW_DEBUG("Response:~n~p~n~s~n", [Code, _Response]),
            lager:debug("bandwidth.com empty response: ~p", [Code]),
            {'error', 'empty_response'};
        {'error', _}=E ->
            lager:debug("bandwidth.com request error: ~p", [E]),
            E
    end.
-endif.

%%--------------------------------------------------------------------
%% @private
%% @doc Convert a number order response to json
%%--------------------------------------------------------------------
-spec number_order_response_to_json(any()) -> kz_json:object().
number_order_response_to_json([]) ->
    kz_json:new();
number_order_response_to_json([Xml]) ->
    number_order_response_to_json(Xml);
number_order_response_to_json(Xml) ->
    Props = [{<<"order_id">>, get_cleaned("orderID/text()", Xml)}
             ,{<<"order_number">>, get_cleaned("orderNumber/text()", Xml)}
             ,{<<"order_name">>, get_cleaned("orderName/text()", Xml)}
             ,{<<"ext_ref_id">>, get_cleaned("extRefID/text()", Xml)}
             ,{<<"accountID">>, get_cleaned("accountID/text()", Xml)}
             ,{<<"accountName">>, get_cleaned("accountName/text()", Xml)}
             ,{<<"quantity">>, get_cleaned("quantity/text()", Xml)}
             ,{<<"number">>, number_search_response_to_json(
                               xmerl_xpath:string("telephoneNumbers/telephoneNumber", Xml)
                              )
              }
            ],
    kz_json:from_list(props:filter_undefined(Props)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert a number search response XML entity to json
%% @end
%%--------------------------------------------------------------------
-spec number_search_response_to_json(xml_el() | xml_els()) -> kz_json:object().
number_search_response_to_json([]) ->
    kz_json:new();
number_search_response_to_json([Xml]) ->
    number_search_response_to_json(Xml);
number_search_response_to_json(Xml) ->
    Props = [{<<"number_id">>, get_cleaned("numberID/text()", Xml)}
             ,{<<"ten_digit">>, get_cleaned("tenDigit/text()", Xml)}
             ,{<<"formatted_number">>, get_cleaned("formattedNumber/text()", Xml)}
             ,{<<"e164">>, get_cleaned("e164/text()", Xml)}
             ,{<<"npa_nxx">>, get_cleaned("npaNxx/text()", Xml)}
             ,{<<"status">>, get_cleaned("status/text()", Xml)}
             ,{<<"rate_center">>, rate_center_to_json(xmerl_xpath:string("rateCenter", Xml))}
            ],
    kz_json:from_list(props:filter_undefined(Props)).

-spec get_cleaned(kz_deeplist(), xml_el()) -> maybe(binary()).
get_cleaned(Path, Xml) ->
    case kz_util:get_xml_value(Path, Xml) of
        'undefined' -> 'undefined';
        V -> kz_util:strip_binary(V, [$\s, $\n])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert a rate center XML entity to json
%% @end
%%--------------------------------------------------------------------
-spec rate_center_to_json(list()) -> kz_json:object().
rate_center_to_json([]) ->
    kz_json:new();
rate_center_to_json([Xml]) ->
    rate_center_to_json(Xml);
rate_center_to_json(Xml) ->
    Props = [{<<"name">>, get_cleaned("name/text()", Xml)}
             ,{<<"lata">>, get_cleaned("lata/text()", Xml)}
             ,{<<"state">>, get_cleaned("state/text()", Xml)}
            ],
    kz_json:from_list(props:filter_undefined(Props)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Determine if the request was successful, and if not extract any
%% error text
%% @end
%%--------------------------------------------------------------------
-spec verify_response(xml_el()) ->
                             {'ok', xml_el()} |
                             {'error', maybe(binary()) | ne_binaries()}.
verify_response(Xml) ->
    case get_cleaned("/*/status/text()", Xml) of
        <<"success">> ->
            lager:debug("request was successful"),
            {'ok', Xml};
        _ ->
            lager:debug("request failed"),
            {'error', get_cleaned("/*/errors/error/message/text()", Xml)}
    end.
