%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Stephen Delano <stephen@chef.io>
%% Copyright 2013-2014 Chef Software, Inc. All Rights Reserved.

-module(oc_chef_wm_named_policy).

-include("../../include/oc_chef_wm.hrl").

%% Webmachine resource callbacks
-mixin([{oc_chef_wm_base, [content_types_accepted/2,
                           content_types_provided/2,
                           finish_request/2,
                           malformed_request/2,
                           ping/2,
                           forbidden/2,
                           is_authorized/2,
                           service_available/2]}]).

-export([allowed_methods/2,
         delete_resource/2,
         from_json/2,
         resource_exists/2,
         to_json/2,
         create_path/2]).

%% chef_wm behavior callbacks
-behaviour(chef_wm).
-export([auth_info/2,
         init/1,
         init_resource_state/1,
         malformed_request_message/3,
         request_type/0,
         validate_request/3,
         conflict_message/1,
         post_is_create/2]).

-define(VALIDATION_CONSTRAINTS,
        {[{<<"name">>, {string_match, chef_regex:regex_for(policy_file_name)}},

          {<<"run_list">>, chef_json_validator:run_list_spec()},

          {<<"cookbook_locks">>,
           {object_map, {
              {keys, {string_match, chef_regex:regex_for(cookbook_name)}},
              {values,
               %% apparently there's no cleaner way to do that with `ej:valid' (??)
               {fun_match, {fun valid_cookbook_lock/1, object,
                            <<"Invalid cookbook_lock constraint">>}}}}}}
         ]}).

-define(COOKBOOK_LOCK_VAIDATION_CONSTRAINTS,
        {[{<<"dotted_decimal_identifier">>,
           chef_cookbook_version:single_cookbook_version_spec()},
          {<<"identifier">>,
           {string_match, chef_regex:regex_for(policy_identifier)}},

          {{opt, <<"version">>},
           chef_cookbook_version:single_cookbook_version_spec()}]}).

valid_cookbook_lock(CookbookLockJson) ->
    case ej:valid(?COOKBOOK_LOCK_VAIDATION_CONSTRAINTS, CookbookLockJson) of
        ok -> ok;
        _Bad -> error
    end.

init(Config) ->
    oc_chef_wm_base:init(?MODULE, Config).

init_resource_state(_Config) ->
    {ok, #policy_state{}}.

request_type() ->
    "policies".

allowed_methods(Req, State) ->
    {['GET', 'PUT', 'POST', 'DELETE'], Req, State}.

post_is_create(Req, State) ->
    {true, Req, State}.

create_path(Req, State) ->
    Name = wrq:path_info(policy_name, Req),
    {Name, Req, State}.

validate_request(Method, Req,
                 State = #base_state{organization_guid = OrgId})
  when Method == 'GET'; Method == 'DELETE' ->
    Name = wrq:path_info(policy_name, Req),
    Group = wrq:path_info(policy_group, Req),
    {Req, State#base_state{superuser_bypasses_checks = true,
               resource_state = #policy_state{
                     oc_chef_policy = #oc_chef_policy{
                         org_id = OrgId,
                         name = Name,
                         policy_group = Group}
                     }
              }
    };
validate_request(_PostOrPut, Req, #base_state{organization_guid = OrgId,
                                              resource_state = PolicyState
                                             } = State) ->
    Policy = validate_json(Req),
    Group = wrq:path_info(policy_group, Req),
    {Req, State#base_state{
            superuser_bypasses_checks = true,
            resource_state = PolicyState#policy_state{
                               oc_chef_policy = #oc_chef_policy{org_id = OrgId,
                                                                policy_group = Group
                                                               },
                               policy_data = Policy}}}.

validate_json(Req) ->
    Body = wrq:req_body(Req),
    {ok, Policy} = oc_chef_policy:parse_binary_json(Body),
    ok = validate_name(Req, Policy),
    case ej:valid(?VALIDATION_CONSTRAINTS, Policy) of
        ok ->
            Policy;
        Bad ->
            throw(Bad)
    end.

validate_name(Req, Policy) ->
    NameFromReq = wrq:path_info(policy_name, Req),
    NameFromJson = erlang:binary_to_list(
                     ej:get({<<"name">>}, Policy, list_to_binary(
                                                    wrq:path_info(policy_name, Req)
                                                   )
                           )
                    ),
    case ibrowse_lib:url_encode(NameFromJson) =:= ibrowse_lib:url_encode(NameFromReq) of
        true ->
            ok;
        false ->
            erlang:throw({mismatch, {<<"Name">>, NameFromJson, NameFromReq}})
    end.

auth_info(Req, #base_state{chef_db_context = DbContext,
                           resource_state = PolicyState = #policy_state{},
                           organization_guid = OrgId} =State) ->
    PolicyName = chef_wm_util:extract_from_path(policy_name, Req),
    case wrq:method(Req) of
        PostOrPut when PostOrPut =:= 'POST'; PostOrPut =:= 'PUT' ->
            validate_policy(true, OrgId, PolicyName, DbContext, Req, State, PolicyState);
        _DeleteOrGet ->
            validate_policy(false, OrgId, PolicyName, DbContext, Req, State, PolicyState)
    end.
validate_policy(CanCreate, _OrgId, PolicyName, DbContext, Req,
                #base_state{} = State, PolicyState = #policy_state{
                                                        oc_chef_policy = InputPolicy
                                                       }) ->
    PolicyWithName = InputPolicy#oc_chef_policy{name = PolicyName},
    case {chef_db:fetch(PolicyWithName, DbContext), CanCreate} of
        {not_found, true} ->
            {{create_in_container, policies}, Req,
             State#base_state{resource_state =
                                  PolicyState#policy_state{create_policy = true}}};
        {not_found, false} ->
            Message = chef_wm_util:error_message_envelope(
                        iolist_to_binary(["Cannot load policy ", PolicyName])),
            Req1 = chef_wm_util:set_json_body(Req, Message),
            {{halt, 404}, Req1, State#base_state{log_msg = policy_not_found}};
        {forbidden, _} ->
            Message = chef_wm_util:error_message_envelope(
                        iolist_to_binary(["No permission for policy ", PolicyName])),
            Req1 = chef_wm_util:set_json_body(Req, Message),
            {{halt, 403}, Req1, State#base_state{log_msg = policy_not_found}};
        {#oc_chef_policy{authz_id = AuthzId} = Policy, _} ->
            PolicyState1 = PolicyState#policy_state{oc_chef_policy = Policy},
            State1 = State#base_state{resource_state = PolicyState1},
            {{object, AuthzId}, Req, State1}
    end.

resource_exists(Req, State) ->
    {true, Req, State}.

to_json(Req, #base_state{
                organization_name = OrgName,
                resource_state = #policy_state{
                                    oc_chef_policy = Policy
                                   }} = State) ->
    Ejson = oc_chef_policy:assemble_policy_ejson(Policy, OrgName),

    {jiffy:encode(Ejson), Req, State}.

from_json(Req, #base_state{resource_state = #policy_state{
                                               create_policy = false,
                                               oc_chef_policy = Policy,
                                               policy_data = PolicyData
                                              }
                          } = State) ->
    Group = wrq:path_info(policy_group, Req),
    UpdatedPolicy = Policy#oc_chef_policy{policy_group = list_to_binary(Group)},
    oc_chef_wm_base:update_from_json(Req, State, UpdatedPolicy, PolicyData);
from_json(Req, #base_state{resource_state = #policy_state{
                                               create_policy = true,
                                               policy_authz_id = AuthzId,
                                               policy_data = PolicyData
                                              }
                          } = State) ->
    Group = wrq:path_info(policy_group, Req),
    UpdatedPolicyData = ej:set({<<"policy_group">>}, PolicyData, Group),
    oc_chef_wm_base:create_from_json(Req, State, oc_chef_policy, {authz_id, AuthzId},
                                     UpdatedPolicyData).

conflict_message(_Name) ->
    {[{<<"error">>, <<"Policy already exists">>}]}.


delete_resource(Req, #base_state{
                        organization_name = OrgName,
                        chef_db_context = DbContext,
                        requestor_id = RequestorId,
                        resource_state = #policy_state{
                                            oc_chef_policy = InputPolicy }
                       } = State) ->
    Group = wrq:path_info(policy_group, Req),
    Policy = InputPolicy#oc_chef_policy{
               last_updated_by = RequestorId,
               policy_group = Group
              },
    ok = oc_chef_wm_base:delete_object(DbContext, Policy, RequestorId),
    Ejson = oc_chef_policy:assemble_policy_ejson(Policy, OrgName),
    {true, chef_wm_util:set_json_body(Req, Ejson), State}.

malformed_request_message(Any, _Req, _state) ->
    error({unexpected_malformed_request_message, Any}).
