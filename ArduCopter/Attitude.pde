/// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-

// get_smoothing_gain - returns smoothing gain to be passed into attitude_control.angle_ef_roll_pitch_rate_ef_yaw_smooth
//      result is a number from 2 to 12 with 2 being very sluggish and 12 being very crisp
float get_smoothing_gain()
{
    return (2.0f + (float)g.rc_feel_rp/10.0f);
}

// get_pilot_desired_angle - transform pilot's roll or pitch input into a desired lean angle
// returns desired angle in centi-degrees
static void get_pilot_desired_lean_angles(int16_t roll_in, int16_t pitch_in, int16_t &roll_out, int16_t &pitch_out)
{
    static float _scaler = 1.0;
    static int16_t _angle_max = 0;

    // range check the input
    roll_in = constrain_int16(roll_in, -ROLL_PITCH_INPUT_MAX, ROLL_PITCH_INPUT_MAX);
    pitch_in = constrain_int16(pitch_in, -ROLL_PITCH_INPUT_MAX, ROLL_PITCH_INPUT_MAX);

    // return filtered roll if no scaling required
    if (aparm.angle_max == ROLL_PITCH_INPUT_MAX) {
        roll_out = roll_in;
        pitch_out = pitch_in;
        return;
    }

    // check if angle_max has been updated and redo scaler
    if (aparm.angle_max != _angle_max) {
        _angle_max = aparm.angle_max;
        _scaler = (float)aparm.angle_max/(float)ROLL_PITCH_INPUT_MAX;
    }

    // convert pilot input to lean angle
    roll_out = (int16_t)((float)roll_in * _scaler);
    pitch_out = (int16_t)((float)pitch_in * _scaler);
}

// get_pilot_desired_heading - transform pilot's yaw input into a desired heading
// returns desired angle in centi-degrees
// To-Do: return heading as a float?
static float get_pilot_desired_yaw_rate(int16_t stick_angle)
{
    // convert pilot input to the desired yaw rate
    return stick_angle * g.acro_yaw_p;
}

/*************************************************************
 * yaw controllers
 *************************************************************/

// get_roi_yaw - returns heading towards location held in roi_WP
// should be called at 100hz
static float get_roi_yaw()
{
    static uint8_t roi_yaw_counter = 0;     // used to reduce update rate to 10hz

    roi_yaw_counter++;
    if (roi_yaw_counter >= 10) {
        roi_yaw_counter = 0;
        yaw_look_at_WP_bearing = pv_get_bearing_cd(inertial_nav.get_position(), roi_WP);
    }

    return yaw_look_at_WP_bearing;
}

static float get_look_ahead_yaw()
{
    // Commanded Yaw to automatically look ahead.
    if (g_gps->fix && g_gps->ground_speed_cm > YAW_LOOK_AHEAD_MIN_SPEED) {
        yaw_look_ahead_bearing = g_gps->ground_course_cd;
    }
    return yaw_look_ahead_bearing;
}

/*************************************************************
 *  throttle control
 ****************************************************************/

// update_thr_cruise - update throttle cruise if necessary
//  should be called at 100hz
static void update_thr_cruise()
{
    // ensure throttle_avg has been initialised
    if( throttle_avg == 0 ) {
        throttle_avg = g.throttle_cruise;
        // update position controller
        pos_control.set_throttle_hover(throttle_avg);
    }

    // if not armed or landed exit
    if (!motors.armed() || ap.land_complete) {
        return;
    }

    // get throttle output
    int16_t throttle = g.rc_3.servo_out;

    // calc average throttle if we are in a level hover
    if (throttle > g.throttle_min && abs(climb_rate) < 60 && labs(ahrs.roll_sensor) < 500 && labs(ahrs.pitch_sensor) < 500) {
        throttle_avg = throttle_avg * 0.99f + (float)throttle * 0.01f;
        g.throttle_cruise = throttle_avg;
    // update position controller
    pos_control.set_throttle_hover(throttle_avg);
    }
}

// set_throttle_takeoff - allows parents to tell throttle controller we are taking off so I terms can be cleared
static void
set_throttle_takeoff()
{
    // tell position controller to reset alt target and reset I terms
    pos_control.init_takeoff();

    // tell motors to do a slow start
    motors.slow_start(true);
}

// get_pilot_desired_throttle - transform pilot's throttle input to make cruise throttle mid stick
// used only for manual throttle modes
// returns throttle output 0 to 1000
#define THROTTLE_IN_MIDDLE 500          // the throttle mid point
static int16_t get_pilot_desired_throttle(int16_t throttle_control)
{
    int16_t throttle_out;

    // exit immediately in the simple cases
    if( throttle_control == 0 || g.throttle_mid == 500) {
        return throttle_control;
    }

    // ensure reasonable throttle values
    throttle_control = constrain_int16(throttle_control,0,1000);
    g.throttle_mid = constrain_int16(g.throttle_mid,300,700);

    // check throttle is above, below or in the deadband
    if (throttle_control < THROTTLE_IN_MIDDLE) {
        // below the deadband
        throttle_out = g.throttle_min + ((float)(throttle_control-g.throttle_min))*((float)(g.throttle_mid - g.throttle_min))/((float)(500-g.throttle_min));
    }else if(throttle_control > THROTTLE_IN_MIDDLE) {
        // above the deadband
        throttle_out = g.throttle_mid + ((float)(throttle_control-500))*(float)(1000-g.throttle_mid)/500.0f;
    }else{
        // must be in the deadband
        throttle_out = g.throttle_mid;
    }

    return throttle_out;
}

// get_pilot_desired_climb_rate - transform pilot's throttle input to
// climb rate in cm/s.  we use radio_in instead of control_in to get the full range
// without any deadzone at the bottom
#define THROTTLE_IN_DEADBAND_TOP (THROTTLE_IN_MIDDLE+THROTTLE_IN_DEADBAND)  // top of the deadband
#define THROTTLE_IN_DEADBAND_BOTTOM (THROTTLE_IN_MIDDLE-THROTTLE_IN_DEADBAND)  // bottom of the deadband
static int16_t get_pilot_desired_climb_rate(int16_t throttle_control)
{
    int16_t desired_rate = 0;

    // throttle failsafe check
    if( failsafe.radio ) {
        return 0;
    }

    // ensure a reasonable throttle value
    throttle_control = constrain_int16(throttle_control,0,1000);

    // check throttle is above, below or in the deadband
    if (throttle_control < THROTTLE_IN_DEADBAND_BOTTOM) {
        // below the deadband
        desired_rate = (int32_t)g.pilot_velocity_z_max * (throttle_control-THROTTLE_IN_DEADBAND_BOTTOM) / (THROTTLE_IN_MIDDLE - THROTTLE_IN_DEADBAND);
    }else if (throttle_control > THROTTLE_IN_DEADBAND_TOP) {
        // above the deadband
        desired_rate = (int32_t)g.pilot_velocity_z_max * (throttle_control-THROTTLE_IN_DEADBAND_TOP) / (THROTTLE_IN_MIDDLE - THROTTLE_IN_DEADBAND);
    }else{
        // must be in the deadband
        desired_rate = 0;
    }

    // desired climb rate for logging
    desired_climb_rate = desired_rate;

    return desired_rate;
}

// get_throttle_surface_tracking - hold copter at the desired distance above the ground
//      returns climb rate (in cm/s) which should be passed to the position controller
static float get_throttle_surface_tracking(int16_t target_rate, float current_alt_target, float dt)
{
    static uint32_t last_call_ms = 0;
    float distance_error;
    float velocity_correction;

    uint32_t now = millis();

    // reset target altitude if this controller has just been engaged
    if( now - last_call_ms > 200 ) {
        target_sonar_alt = sonar_alt + current_alt_target - current_loc.alt;
    }
    last_call_ms = now;

    // adjust sonar target alt if motors have not hit their limits
    if ((target_rate<0 && !motors.limit.throttle_lower) || (target_rate>0 && !motors.limit.throttle_upper)) {
        target_sonar_alt += target_rate * dt;
    }

    // do not let target altitude get too far from current altitude above ground
    // Note: the 750cm limit is perhaps too wide but is consistent with the regular althold limits and helps ensure a smooth transition
    target_sonar_alt = constrain_float(target_sonar_alt,sonar_alt-pos_control.get_leash_down_z(),sonar_alt+pos_control.get_leash_up_z());

    // calc desired velocity correction from target sonar alt vs actual sonar alt
    distance_error = target_sonar_alt-sonar_alt;
    velocity_correction = distance_error * g.sonar_gain;
    velocity_correction = constrain_float(velocity_correction, -THR_SURFACE_TRACKING_VELZ_MAX, THR_SURFACE_TRACKING_VELZ_MAX);

    // return combined pilot climb rate + rate to correct sonar alt error
    return (target_rate + velocity_correction);
}

// set_accel_throttle_I_from_pilot_throttle - smoothes transition from pilot controlled throttle to autopilot throttle
static void set_accel_throttle_I_from_pilot_throttle(int16_t pilot_throttle)
{
    // shift difference between pilot's throttle and hover throttle into accelerometer I
    g.pid_throttle_accel.set_integrator(pilot_throttle-g.throttle_cruise);
}
