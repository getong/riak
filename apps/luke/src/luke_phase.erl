%% Copyright (c) 2010 Basho Technologies, Inc.  All Rights Reserved.

%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0

%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

-module(luke_phase).

-behaviour(gen_fsm).

%% API
-export([start_link/7,
         complete/0,
         partners/3]).

%% Behaviour
-export([behaviour_info/1]).

%% States
-export([executing/2]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-record(state, {id,
                mod,
                modstate,
                converge=false,
                accumulate=false,
                lead_partner,
                partners,
                next_phases,
                done_count=1,
                flow,
                flow_timeout}).

behaviour_info(callbacks) ->
  [{init, 1},
   {handle_timeout, 1},
   {handle_input, 3},
   {handle_input_done, 1},
   {handle_event, 2},
   {handle_info, 2},
   {terminate, 2}];
behaviour_info(_) ->
    undefined.

start_link(PhaseMod, Id, Behaviors, NextPhases, Flow, Timeout, PhaseArgs) ->
    gen_fsm:start_link(?MODULE, [Id, PhaseMod, Behaviors, NextPhases, Flow, Timeout, PhaseArgs], []).

complete() ->
    gen_fsm:send_event(self(), complete).

partners(PhasePid, Leader, Partners) ->
    gen_fsm:send_event(PhasePid, {partners, Leader, Partners}).

init([Id, PhaseMod, Behaviors, NextPhases, Flow, Timeout, PhaseArgs]) ->
    case PhaseMod:init(PhaseArgs) of
        {ok, ModState} ->
            Accumulate = lists:member(accumulate, Behaviors),
            Converge = lists:member(converge, Behaviors),
            {ok, executing, #state{id=Id, mod=PhaseMod, modstate=ModState, next_phases=NextPhases,
                                   flow=Flow, accumulate=Accumulate, converge=Converge, flow_timeout=Timeout}};
        {stop, Reason} ->
            {stop, Reason}
    end.

executing({partners, Lead0, Partners0}, #state{converge=true}=State) when is_list(Partners0) ->
    Me = self(),
    Lead = case Lead0 of
               Me ->
                   undefined;
               _ ->
                   erlang:link(Lead0),
                   Lead0
           end,
    Partners = lists:delete(self(), Partners0),
    DoneCount = if
                    Lead =:= undefined ->
                        length(Partners) + 1;
                    true ->
                        1
                end,
    {next_state, executing, State#state{lead_partner=Lead, partners=Partners, done_count=DoneCount}};
executing({partners, _, _}, State) ->
    {stop, {error, no_convergence}, State};
executing({inputs, Input}, #state{mod=PhaseMod, modstate=ModState, flow_timeout=Timeout}=State) ->
    handle_callback(PhaseMod:handle_input(Input, ModState, Timeout), State);
executing(inputs_done, #state{mod=PhaseMod, modstate=ModState, done_count=DoneCount0}=State) ->
    case DoneCount0 - 1 of
        0 ->
            handle_callback(PhaseMod:handle_input_done(ModState), State#state{done_count=0});
        DoneCount ->
            {next_state, executing, State#state{done_count=DoneCount}}
    end;
executing(complete, #state{lead_partner=Leader}=State) when is_pid(Leader) ->
    luke_phases:send_inputs_done(Leader),
    {stop, normal, State};
executing(complete, #state{flow=Flow, next_phases=Next}=State) ->
    case Next of
        undefined ->
            luke_phases:send_flow_complete(Flow);
        _ ->
            luke_phases:send_inputs_done(Next)
    end,
    {stop, normal, State};
executing(timeout, #state{mod=Mod, modstate=ModState}=State) ->
    handle_callback(Mod:handle_timeout(ModState), State);
executing(timeout, State) ->
    {stop, normal, State};
executing(Event, #state{mod=PhaseMod, modstate=ModState}=State) ->
    handle_callback(PhaseMod:handle_event(Event, ModState), State).

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ignored, StateName, State}.
handle_info(timeout, executing, #state{mod=Mod, modstate=ModState}=State) ->
    handle_callback(Mod:handle_timeout(ModState), State);
handle_info(Info, _StateName, #state{mod=PhaseMod, modstate=ModState}=State) ->
    handle_callback(PhaseMod:handle_info(Info, ModState), State).

terminate(Reason, _StateName, #state{mod=PhaseMod, modstate=ModState}) ->
    PhaseMod:terminate(Reason, ModState),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% Internal functions
%% Handle callback module return values
handle_callback({no_output, NewModState}, State) ->
    {next_state, executing, State#state{modstate=NewModState}};
handle_callback({no_output, NewModState, PhaseTimeout}, #state{flow_timeout=Timeout}=State) when PhaseTimeout < Timeout ->
    {next_state, executing, State#state{modstate=NewModState}, PhaseTimeout};
handle_callback({output, Output, NewModState}, State) ->
    State1 = route_output(Output, State),
    {next_state, executing, State1#state{modstate=NewModState}};
handle_callback({output, Output, NewModState, PhaseTimeout}, #state{flow_timeout=Timeout}=State) when PhaseTimeout < Timeout ->
    State1 = route_output(Output, State),
    {next_state, executing, State1#state{modstate=NewModState}, PhaseTimeout};
handle_callback({stop, Reason, NewModState}, State) ->
    {stop, Reason, State#state{modstate=NewModState}};
handle_callback(BadValue, _State) ->
  throw({error, {bad_return, BadValue}}).

%% Route output to lead when converging
%% Accumulation is ignored for non-leads of converging phases
%% since all accumulation is performed in the lead process
route_output(Output, #state{converge=true, lead_partner=Lead}=State) when is_pid(Lead) ->
    propagate_inputs([Lead], Output),
    State;

%% Send output to flow for accumulation and propagate as inputs
%% to the next phase. Accumulation is only true for the lead
%% process of a converging phase
route_output(Output, #state{id=Id, converge=true, accumulate=Accumulate, lead_partner=undefined,
                            flow=Flow, next_phases=Next}=State) ->
    if
        Accumulate =:= true ->
            luke_phases:send_flow_results(Flow, Id, Output);
        true ->
            ok
    end,
    RotatedNext = propagate_inputs(Next, Output),
    State#state{next_phases=RotatedNext};

%% Route output to the next phase. Accumulate output
%% to the flow if accumulation is turned on.
route_output(Output, #state{id=Id, converge=false, accumulate=Accumulate, flow=Flow, next_phases=Next} = State) ->
    if
        Accumulate =:= true ->
            luke_phases:send_flow_results(Flow, Id, Output);
        true ->
            ok
    end,
    RotatedNext = propagate_inputs(Next, Output),
    State#state{next_phases=RotatedNext}.

propagate_inputs(undefined, _Results) ->
    undefined;
propagate_inputs(Next, Results) ->
    luke_phases:send_inputs(Next, Results).
