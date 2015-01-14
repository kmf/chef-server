%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Stephen Delano <stephen@opscode.com>
%% Copyright 2013 Opscode, Inc. All Rights Reserved.

-module(oc_chef_policy).

-include("../../include/oc_chef_types.hrl").
-include_lib("mixer/include/mixer.hrl").

-behaviour(chef_object).

-define(DEFAULT_HEADERS, []).

-export([
         parse_binary_json/1,
         flatten/1,
         assemble_policy_ejson/2,
         delete/2,
         create_record/3
        ]).

%% chef_object behaviour callbacks
-export([
         id/1,
         authz_id/1,
         bulk_get_query/0,
         create_query/0,
         delete_query/0,
         ejson_for_indexing/2,
         fields_for_fetch/1,
         fields_for_update/1,
         find_query/0,
         is_indexed/0,
         list/2,
         list_query/0,
         name/1,
         new_record/3,
         org_id/1,
         record_fields/0,
         set_created/2,
         set_updated/2,
         type_name/1,
         update_from_ejson/2,
         update_query/0,
         update/2,
         fetch/2
        ]).

id(#oc_chef_policy{id = Id}) ->
    Id.

name(#oc_chef_policy{name = Name}) ->
    Name.

policy_group(#oc_chef_policy{policy_group = PolicyGroup}) ->
    PolicyGroup.

org_id(#oc_chef_policy{org_id = OrgId}) ->
    OrgId.

type_name(#oc_chef_policy{}) ->
    policy.

authz_id(#oc_chef_policy{authz_id = AuthzId}) ->
    AuthzId.


create_query() ->
    insert_policy.

update_query() ->
    update_policy_by_id.

delete_query() ->
    delete_policy_by_name_group_org_id.

find_query() ->
    find_policy_by_orgid_name_group.

list_query() ->
    list_policies_for_org.

bulk_get_query() ->
    %% TODO: do we need this?
    ok.

new_record(OrgId, AuthzId, PolicyData) ->
    Name = ej:get({<<"name">>}, PolicyData),
    Id = chef_object_base:make_org_prefix_id(OrgId, Name),
    PolicyGroup = list_to_binary(ej:get({<<"policy_group">>}, PolicyData)),
    #oc_chef_policy{
       id = Id,
       authz_id = AuthzId,
                       org_id = OrgId,
                       name = Name,
                       policy_group = PolicyGroup,
      serialized_object = ej:delete({<<"policy_group">>}, PolicyData)}.

create_record(OrgId, Name, RequestingActorId) ->
    Policy = #oc_chef_policy{
                           org_id = OrgId,
                           name = Name},
    set_created(Policy, RequestingActorId).

set_created(#oc_chef_policy{} = Object, ActorId) ->
    Object#oc_chef_policy{last_updated_by = ActorId}.

set_updated(#oc_chef_policy{} = Object, ActorId) ->
    Object#oc_chef_policy{last_updated_by = ActorId}.

is_indexed() ->
    false.

ejson_for_indexing(#oc_chef_policy{}, _EjsonTerm) ->
   {[]}.

update_from_ejson(#oc_chef_policy{} = Policy, PolicyData) ->
    Name = ej:get({<<"name">>}, PolicyData, name(Policy)),
    Policy#oc_chef_policy{
             name = Name,
             serialized_object = PolicyData
						 }.

fields_for_update(#oc_chef_policy{
                     id = Id,
                     last_updated_by = LastUpdatedBy,
                     serialized_object = SerializedObject
                                 } = Policy) ->
    [LastUpdatedBy, name(Policy), policy_group(Policy), chef_db_compression:compress(oc_chef_policy, jiffy:encode(SerializedObject)), Id].


fields_for_fetch(#oc_chef_policy{org_id = OrgId} = Policy) ->
    [name(Policy), policy_group(Policy), OrgId].

record_fields() ->
    record_info(fields, oc_chef_policy).

list(#oc_chef_policy{org_id = OrgId}, CallbackFun) ->
    CallbackFun({list_query(), [OrgId], rows}).

update(#oc_chef_policy{
                      org_id = _OrgId,
                      authz_id = _PolicyAuthzId,
                      last_updated_by = _AuthzId
                     } = Record, CallbackFun) ->
	chef_object:default_update(Record, CallbackFun).


parse_binary_json(Bin) ->
    {ok, chef_json:decode_body(Bin)}.


fetch(#oc_chef_policy{} = Record, CallbackFun) ->
    chef_object:default_fetch(Record, CallbackFun).


flatten(#oc_chef_policy{
          id = Id,
          authz_id = AuthzId,
          org_id = OrgId,
          name = Name,
          policy_group = Group,
          last_updated_by = LastUpdatedBy,
          serialized_object = SerializedObject}) ->
	Compressed = chef_db_compression:compress(oc_chef_policy, jiffy:encode(ej:delete({<<"policy_group">>}, SerializedObject))),
    [Id, AuthzId, OrgId, Name, Group, LastUpdatedBy, Compressed].


assemble_policy_ejson(#oc_chef_policy{
                         serialized_object = SerializedObject
                        }, _OrgName) ->
    jiffy:decode(chef_db_compression:decompress(SerializedObject)).

delete(ObjectRec = #oc_chef_policy{
                      org_id = OrgId,
                      last_updated_by = _AuthzId,
                      authz_id = _PolicyAuthzId
                     }, CallbackFun) ->
    CallbackFun({delete_query(), [name(ObjectRec), policy_group(ObjectRec), OrgId]}).
