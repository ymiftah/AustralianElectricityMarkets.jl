function preprocess_fast_start(input::FastStartInput)
    state = input.state
    profile = input.profile
    if state.mode == 0 && input.previous_total_cleared > 0 && input.max_avail > 0
        state = input.initial_mw < 1 ? FastStartState(0, 0.0) : FastStartState(4, profile.t4_minutes)
    elseif iszero(input.max_avail)
        state = input.initial_mw < 1 && state.mode == 0 ?
            FastStartState(0, 0.0) : FastStartState(4, profile.t4_minutes)
    end
    return FastStartInput(
        profile, state, input.initial_mw, input.ramp_up_rate, input.ramp_down_rate,
        input.max_avail, input.previous_total_cleared,
    )
end

function _advance_fast_start(profile::FastStartProfile, state::FastStartState, interval_minutes::Real)
    mode = state.mode
    elapsed = state.elapsed_minutes
    remaining = Float64(interval_minutes)
    while 1 <= mode <= 3
        duration = mode == 1 ? profile.t1_minutes : mode == 2 ? profile.t2_minutes : profile.t3_minutes
        if iszero(duration)
            mode += 1
            elapsed = 0.0
        elseif remaining == 0
            break
        else
            segment_remaining = duration - elapsed
            if remaining <= segment_remaining
                elapsed += remaining
                remaining = 0.0
                break
            else
                remaining -= segment_remaining
                mode += 1
                elapsed = 0.0
            end
        end
    end
    if mode == 4
        elapsed += remaining
    end
    return FastStartState(mode, elapsed)
end

function _fast_start_profile_mw(profile::FastStartProfile, state::FastStartState)
    if state.mode <= 1
        return 0.0
    elseif state.mode == 2
        return iszero(profile.t2_minutes) ? 0.0 : profile.minimum_load_mw * state.elapsed_minutes / profile.t2_minutes
    elseif state.mode == 3
        return profile.minimum_load_mw
    end
    return iszero(profile.t4_minutes) ? 0.0 :
        profile.minimum_load_mw * max(0.0, 1.0 - state.elapsed_minutes / profile.t4_minutes)
end

function _time_to_minimum_load(input::FastStartInput)
    state = input.state
    profile = input.profile
    if state.mode == 0
        return profile.t1_minutes + profile.t2_minutes
    elseif state.mode == 1
        return max(0.0, profile.t1_minutes - state.elapsed_minutes) + profile.t2_minutes
    end
    return max(0.0, profile.t2_minutes - state.elapsed_minutes)
end

function plan_fast_start(input::FastStartInput, candidate_mw::Real; interval_minutes::Real = 5.0)
    input = preprocess_fast_start(input)
    starting_mode = input.state.mode
    if starting_mode == 0
        state = candidate_mw > 0.005 ? FastStartState(1, 0.0) : FastStartState(0, 0.0)
    else
        state = input.state
    end
    state = _advance_fast_start(input.profile, state, interval_minutes)
    profile_mw = _fast_start_profile_mw(input.profile, state)
    profile_upper_mw = state.mode <= 2 ? profile_mw : nothing

    if starting_mode <= 2 && state.mode >= 3
        ramp_initial_mw = input.profile.minimum_load_mw
        ramp_minutes = max(0.0, Float64(interval_minutes) - _time_to_minimum_load(input))
    elseif starting_mode >= 3
        ramp_initial_mw = input.initial_mw
        ramp_minutes = Float64(interval_minutes)
    else
        ramp_initial_mw = 0.0
        ramp_minutes = nothing
    end
    can_shutdown = state.mode == 4 && state.elapsed_minutes >= input.profile.t4_minutes &&
        input.initial_mw - input.ramp_down_rate * Float64(interval_minutes) / 60 <= 0.005
    return (
        state = state,
        profile_lower_mw = profile_mw,
        profile_upper_mw = profile_upper_mw,
        ramp_initial_mw = ramp_initial_mw,
        ramp_minutes = ramp_minutes,
        can_shutdown = can_shutdown,
    )
end

function finalize_fast_start_state(envelope, dispatch_mw::Real)
    if envelope.can_shutdown && dispatch_mw <= 0.005
        return FastStartState(0, 0.0)
    end
    return envelope.state
end
