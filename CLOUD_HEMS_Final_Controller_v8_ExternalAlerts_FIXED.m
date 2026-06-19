clc; clear; close all;
rng(1);

%% =========================================================
% CLOUD_HEMS_Final_Controller_v8_ExternalAlerts_FIXED.m
%
% Cloud-ready modular Residential HEMS controller
%
% Purpose:
%   This script is the cloud-deployment version of the final EMS framework.
%   It is NOT a paper comparison script. It is an operational controller
%   that reads the latest measurements/forecasts, detects faults, estimates
%   grid-risk, applies PV-return look-ahead, and produces EMS decisions.
%
% Integrated logic:
%   1) DL load/PV forecast inputs
%   2) PV-return look-ahead night charging suppression
%   3) No-leakage learned grid-risk from previous grid availability history
%   4) Hybrid EMS-level fault detection
%   5) Fault-aware EMS response
%   6) Optional cooperative Master-to-Slave sharing support
%
% Main outputs:
%   CLOUD_HEMS_Decisions.csv
%   CLOUD_HEMS_Summary.csv
%   Fig_CLOUD_HEMS_SOC.png
%   Fig_CLOUD_HEMS_PowerBalance.png
%   Fig_CLOUD_HEMS_RiskFaultFlags.png
%
% Notes:
%   - For offline validation, set USE_API_INPUT = false and use a CSV file.
%   - For cloud deployment, replace getLatestCloudDataPlaceholder() with
%     your real API/data-ingestion function.
%   - This controller is intentionally modular and practical. It avoids
%     future-information leakage by using only current and previous data
%     for grid-risk estimation. Forecast look-ahead uses predicted future
%     load/PV, which is allowed because these are forecast inputs.
%% =========================================================

%% =========================================================
% 1) USER SETTINGS
%% =========================================================

USE_API_INPUT = false;   % false = CSV simulation, true = cloud/API placeholder

% Cloud testing option:
% If the offline CSV does not contain real GridAvailable outage history,
% enable this to test learned grid-risk behavior without using future leakage.
SIMULATE_GRID_HISTORY_FOR_CLOUD_TEST = true;
CLOUD_GRID_HISTORY_PATTERN = "stable";   % "stable", "2off_2on", "mostly_available", "mostly_outage", "3off_1on", "4off_2on"

% Main CSV for offline/cloud simulation.
% Required columns:
%   Time, Load_kW, PV_kW, Load_pred_kW, PV_pred_kW
% Optional columns:
%   SOC_percent, GridAvailable, InverterEfficiency, BatteryCapacityFactor
inputFile = 'Forecasts_3Months_PV_Load_DL_Test20.csv';

% Optional cooperative mode.
% If enabled, the input file should include slave columns if available:
%   Slave_Load_kW, Slave_PV_kW, Slave_SOC_percent
ENABLE_COOPERATIVE_SHARING = false;

% External notification settings (Telegram + Email)
% Set ENABLE_TELEGRAM = true and fill in BOT_TOKEN and CHAT_ID to activate.
% Set ENABLE_EMAIL = true and fill in Gmail credentials to activate.
% Both can be enabled simultaneously. If Telegram fails, Email is sent as backup.
% Leave credentials as placeholders for offline validation.
ENABLE_TELEGRAM   = false;
TELEGRAM_BOT_TOKEN = 'YOUR_BOT_TOKEN';    % From BotFather on Telegram
TELEGRAM_CHAT_ID   = 'YOUR_CHAT_ID';      % Your Telegram chat/user ID

ENABLE_EMAIL      = false;
EMAIL_SENDER      = 'your_email@gmail.com';
EMAIL_PASSWORD    = 'YOUR_APP_PASSWORD';   % Gmail App Password (not login password)
EMAIL_RECIPIENT   = 'your_email@gmail.com';
EMAIL_SMTP_SERVER = 'smtp.gmail.com';

% Cooldown: minimum minutes between repeated alerts of the same type
% Prevents flooding during long outage periods
ALERT_COOLDOWN_MINUTES = 60;

% Output files
% Same-folder saving mode:
% Results are saved directly in the MATLAB Current Folder.
% Close any open CSV files before rerunning to avoid Permission denied errors.
outputFolder = pwd;

decisionFile = fullfile(outputFolder, 'CLOUD_HEMS_Decisions.csv');
summaryFile  = fullfile(outputFolder, 'CLOUD_HEMS_Summary.csv');

%% =========================================================
% 2) SYSTEM PARAMETERS
%% =========================================================

% Battery system: 51.2 V x 900 Ah = 46.08 kWh
E_batt_nominal_kWh = 46.08;

SOC_initial_percent = 70;
SOC_min_normal_percent = 20;
SOC_min_fault_percent  = 30;
SOC_warning_percent = 40;
SOC_critical_percent = 30;
SOC_max_percent = 90;

SOC_target_lowRisk_percent  = 65;
SOC_target_midRisk_percent  = 75;
SOC_target_highRisk_percent = 85;
SOC_target_fault_percent    = 80;

eta_charge = 0.95;
eta_discharge = 0.95;

P_batt_max_normal_kW = 8.0;
P_batt_max_fault_kW  = 4.0;

P_grid_charge_normal_kW = 3.0;
P_grid_charge_fault_kW  = 3.5;
P_grid_charge_emergency_kW = 4.0;

% PV-return look-ahead settings from final Case 7G
PV_return_threshold_kW = 0.70;
maxLookAhead_hours = 12;
reserveMargin_kWh = 6.0;
SOC_hard_safe_percent = 45;

% Learned grid risk settings from final Case 9B/04H logic
gridRiskLearningWindow_days = 3;
riskMedium_outageRatio = 0.20;
riskHigh_outageRatio   = 0.45;
riskMedium_longestOutage_h = 2.0;
riskHigh_longestOutage_h   = 3.0;

% Energy-criticality weighted grid-risk enhancement.
% Instead of assigning fixed peak-hour weights, this uses the forecasted
% net demand: max(Load_pred - PV_pred, 0). Outages during high predicted
% deficit periods receive higher importance. This is no-leakage because
% only previous-day history is used for learning grid-risk.
USE_ENERGY_CRITICALITY_GRID_RISK = true;
criticalityPercentile = 95;      % normalization percentile for predicted net demand
criticalityMaxWeight  = 2.50;    % upper cap to avoid over-weighting extreme points

% Adaptive grid-risk refinements.
% Trend detection raises risk if recent outages are clearly increasing.
% Recovery bonus reduces risk if the most recent grid history is stable.
USE_GRID_RISK_TREND_DETECTION = true;
trendIncreaseFactor = 1.50;      % latest-day ratio must exceed earliest-day ratio by this factor
trendMinIncreaseAbs = 0.10;      % absolute increase required to avoid reacting to tiny changes

USE_GRID_RISK_RECOVERY_BONUS = true;
recoveryStableHours = 12.0;      % reduce risk by one level if the last 12 hours are fully available

% Fault-detection parameters, cloud-light version compatible with final EMS
PV_ratio_drop_limit = 0.55;
PV_abs_drop_min_kW = 0.30;
PV_pred_min_kW = 0.40;

Load_ratio_spike_limit = 1.45;
Load_abs_spike_min_kW = 0.20;
Load_pred_min_kW = 0.10;

Communication_error_min_kW = 0.05;
commWindow = 6;

% Controlled shedding only in severe grid-outage/fault emergency
shedding_light_ratio = 0.10;
shedding_heavy_ratio = 0.25;

% Cooperative sharing parameters
PV_capacity_master_kW = 12.0;
PV_capacity_slave_kW  = 6.0;
Master_SOC_reserve_percent = 70;
eta_transfer = 0.95;
P_transfer_max_kW = 4.0;

%% =========================================================
% 3) READ INPUT DATA
%% =========================================================

inputFile = "https://raw.githubusercontent.com/noorasmlm-ai/HEMS_CLOUD_PROJECT/main/Forecasts_3Months_PV_Load_DL_Test20.csv";

T = readtable(inputFile, 'VariableNamingRule','preserve');
% Time
if isdatetime(T.Time)
    time = T.Time;
else
    time = datetime(T.Time);
end

N = height(T);
if N < 2
    error('Input data is too short.');
end

dt_hours = hours(time(2) - time(1));
samplesPerHour = max(1, round(1/dt_hours));

% Required columns
Load_kW      = max(getCol(T, {'Load_kW','P_load_kW','Consumption_kW'}, N), 0);
PV_kW        = max(getCol(T, {'PV_kW','P_pv_kW','PV_total_kW'}, N), 0);
Load_pred_kW = max(getCol(T, {'Load_pred_kW','P_load_pred_kW','LoadForecast_kW'}, N), 0);
PV_pred_kW   = max(getCol(T, {'PV_pred_kW','P_pv_pred_kW','PVForecast_kW'}, N), 0);

% Optional columns
SOC_measured_percent = getColOptional(T, {'SOC_percent','SoC_percent','SOC'}, N, SOC_initial_percent*ones(N,1));
GridAvailable = logical(round(getColOptional(T, {'GridAvailable','Grid_Available'}, N, ones(N,1))));
InverterEfficiency = getColOptional(T, {'InverterEfficiency','Inverter_Efficiency'}, N, ones(N,1));
BatteryCapacityFactor = getColOptional(T, {'BatteryCapacityFactor','Battery_Capacity_Factor'}, N, ones(N,1));

% Optional cloud-test grid history simulation.
% This is only for offline validation when the CSV has no real outage history.
% It should be disabled when real cloud GridAvailable data are connected.
if SIMULATE_GRID_HISTORY_FOR_CLOUD_TEST
    GridAvailable = simulateGridHistoryForCloudTest(time, CLOUD_GRID_HISTORY_PATTERN);
end

SOC_measured_percent = max(min(SOC_measured_percent, 100), 0);
InverterEfficiency = max(min(InverterEfficiency, 1.0), 0.0);
BatteryCapacityFactor = max(min(BatteryCapacityFactor, 1.0), 0.50);

fprintf('\nCloud HEMS controller input loaded.\n');
fprintf('Samples: %d\n', N);
fprintf('Start  : %s\n', string(time(1)));
fprintf('End    : %s\n', string(time(end)));
fprintf('dt     : %.4f h\n', dt_hours);

%% =========================================================
% 4) LEARNED GRID RISK, NO-LEAKAGE DAILY METHOD
%% =========================================================

dateOnly = dateshift(time, 'start', 'day');
uniqueDays = unique(dateOnly);
D = numel(uniqueDays);

DailyGridRisk = ones(D,1);
DailyRecentOutageRatio = zeros(D,1);
DailyRecentLongestOutage_h = zeros(D,1);

for d = 1:D
    currentDay = uniqueDays(d);
    startHist = currentDay - days(gridRiskLearningWindow_days);
    idxHist = dateOnly >= startHist & dateOnly < currentDay;

    if sum(idxHist) < samplesPerHour
        DailyGridRisk(d) = 1;
        DailyRecentOutageRatio(d) = 0;
        DailyRecentLongestOutage_h(d) = 0;
    else
        outageFlagHist = ~GridAvailable(idxHist);

        % Base outage ratio
        outageRatio = mean(outageFlagHist);

        % Energy-criticality weighted outage ratio.
        % Criticality is based on predicted net demand:
        % netDemand = max(Load_pred - PV_pred, 0)
        % Therefore, outages during high predicted deficit periods receive
        % higher risk weight than outages during low-impact periods.
        if USE_ENERGY_CRITICALITY_GRID_RISK
            netDemandHist_kW = max(Load_pred_kW(idxHist) - PV_pred_kW(idxHist), 0);

            normCriticality = max(prctile(netDemandHist_kW, criticalityPercentile), eps);
            energyWeight = 1 + netDemandHist_kW ./ normCriticality;
            energyWeight = min(energyWeight, criticalityMaxWeight);

            weightedOutageRatio = sum(double(outageFlagHist) .* energyWeight) / max(sum(energyWeight), eps);
        else
            weightedOutageRatio = outageRatio;
        end

        longestOutage_h = longestTrueRunHours(outageFlagHist, dt_hours);

        % Store the learned weighted ratio. If USE_ENERGY_CRITICALITY_GRID_RISK is false,
        % this equals the ordinary outage ratio.
        DailyRecentOutageRatio(d) = weightedOutageRatio;
        DailyRecentLongestOutage_h(d) = longestOutage_h;

        % Base risk classification from weighted outage ratio and longest outage.
        if weightedOutageRatio >= riskHigh_outageRatio || longestOutage_h >= riskHigh_longestOutage_h
            baseRisk = 3;
        elseif weightedOutageRatio >= riskMedium_outageRatio || longestOutage_h >= riskMedium_longestOutage_h
            baseRisk = 2;
        else
            baseRisk = 1;
        end

        % Trend detection: raise risk one level if the learned outage pattern is worsening.
        trendBoost = 0;
        if USE_GRID_RISK_TREND_DETECTION
            histDates = dateOnly(idxHist);
            histOutage = outageFlagHist;
            uHistDays = unique(histDates, 'stable');

            if numel(uHistDays) >= 2
                dayRatio = zeros(numel(uHistDays),1);
                for dd = 1:numel(uHistDays)
                    dayRatio(dd) = mean(histOutage(histDates == uHistDays(dd)));
                end

                earliestRatio = dayRatio(1);
                latestRatio   = dayRatio(end);

                if latestRatio >= earliestRatio * trendIncreaseFactor && ...
                        (latestRatio - earliestRatio) >= trendMinIncreaseAbs
                    trendBoost = 1;
                end
            end
        end

        % Recovery bonus: reduce risk one level if the most recent history is fully stable.
        recoveryDrop = 0;
        if USE_GRID_RISK_RECOVERY_BONUS
            histTime = time(idxHist);
            latestHistTime = max(histTime);
            recentMask = histTime >= latestHistTime - hours(recoveryStableHours);

            histAvailable = GridAvailable(idxHist);
            if any(recentMask) && all(histAvailable(recentMask))
                recoveryDrop = 1;
            end
        end

        DailyGridRisk(d) = min(max(baseRisk + trendBoost - recoveryDrop, 1), 3);
    end
end

GridRiskLevel = zeros(N,1);
for d = 1:D
    GridRiskLevel(dateOnly == uniqueDays(d)) = DailyGridRisk(d);
end

%% =========================================================
% 5) CLOUD-LIGHT FAULT DETECTION
%% =========================================================

LoadResidual_kW = abs(Load_kW - Load_pred_kW);
PVResidual_kW   = abs(PV_kW - PV_pred_kW);

% Online/no-leakage residual threshold for cloud-light communication detection.
% At each time step, the threshold is estimated from previous samples only.
LoadResidualThreshold_Online = zeros(N,1);
for tt = 1:N
    histEnd = max(1, tt-1);
    histResidual = LoadResidual_kW(1:histEnd);
    LoadResidualThreshold_Online(tt) = max(Communication_error_min_kW, prctile(histResidual, 99.5));
end

LoadRatio_toPred = Load_kW ./ max(Load_pred_kW, Load_pred_min_kW);
PVRatio_toPred   = PV_kW ./ max(PV_pred_kW, 0.10);

hourNow = hour(time) + minute(time)/60;
isPVDay = hourNow >= 9.0 & hourNow <= 15.5;

% Status-based faults
F3_Grid_Detected = ~GridAvailable;
F4_Inverter_Detected = InverterEfficiency < 0.95;
F5_BatteryCapacity_Detected = BatteryCapacityFactor < 0.95;

% PV drop detector
F1_PV_raw = ...
    isPVDay & ...
    PV_pred_kW > PV_pred_min_kW & ...
    PVRatio_toPred < PV_ratio_drop_limit & ...
    PV_kW < PV_pred_kW - PV_abs_drop_min_kW & ...
    ~F4_Inverter_Detected & ...
    GridAvailable;

F1_PV_Detected = movingSustain(F1_PV_raw, 3);
F1_PV_Detected = keepLongSegments(F1_PV_Detected, 6);

% Load spike detector
F2_Load_raw = ...
    Load_kW > Load_pred_kW & ...
    LoadResidual_kW > Load_abs_spike_min_kW & ...
    LoadRatio_toPred > Load_ratio_spike_limit & ...
    GridAvailable;

F2_Load_Detected = movingSustain(F2_Load_raw, 2);
F2_Load_Detected = keepLongSegments(F2_Load_Detected, 2);

% Communication delay/freeze detector, cloud-light version
LoadRange = movmax(Load_kW,[commWindow-1 0]) - movmin(Load_kW,[commWindow-1 0]);
PVRange   = movmax(PV_kW,  [commWindow-1 0]) - movmin(PV_kW,  [commWindow-1 0]);

LoadPredRange = movmax(Load_pred_kW,[commWindow-1 0]) - movmin(Load_pred_kW,[commWindow-1 0]);
PVPredRange   = movmax(PV_pred_kW,  [commWindow-1 0]) - movmin(PV_pred_kW,  [commWindow-1 0]);

F6_Comm_raw = ...
    ((LoadRange < 0.01 & LoadPredRange > 0.10) | ...
     (PVRange < 0.01 & PVPredRange > 0.10)) | ...
    (LoadResidual_kW > LoadResidualThreshold_Online);

F6_Comm_Detected = movingSustain(F6_Comm_raw, 2);
F6_Comm_Detected = keepLongSegments(F6_Comm_Detected, 2);

DetectedFaultLabel = F1_PV_Detected | F2_Load_Detected | F3_Grid_Detected | ...
                     F4_Inverter_Detected | F5_BatteryCapacity_Detected | F6_Comm_Detected;

DetectedFaultType = strings(N,1);
DetectedFaultType(:) = "Normal";
DetectedFaultType(F1_PV_Detected) = "F1_PV_Drop";
DetectedFaultType(F2_Load_Detected) = "F2_Load_Spike";
DetectedFaultType(F3_Grid_Detected) = "F3_Grid_Outage";
DetectedFaultType(F4_Inverter_Detected) = "F4_Inverter_Derating";
DetectedFaultType(F5_BatteryCapacity_Detected) = "F5_Battery_Capacity_Reduction";
DetectedFaultType(F6_Comm_Detected) = "F6_Communication_Delay_Freeze";

%% =========================================================
% 6) DAILY FORECAST TARGETS
%% =========================================================

DailyForecastDeficit_kWh = zeros(D,1);
DailySOCTarget_percent = zeros(D,1);

for d = 1:D
    idxD = dateOnly == uniqueDays(d);
    loadE = sum(Load_pred_kW(idxD)) * dt_hours;
    pvE   = sum(PV_pred_kW(idxD)) * dt_hours;
    DailyForecastDeficit_kWh(d) = max(loadE - pvE, 0);

    switch DailyGridRisk(d)
        case 1
            baseTarget = SOC_target_lowRisk_percent;
        case 2
            baseTarget = SOC_target_midRisk_percent;
        otherwise
            baseTarget = SOC_target_highRisk_percent;
    end

    % Forecast deficit can also raise the target
    if DailyForecastDeficit_kWh(d) >= 12
        baseTarget = max(baseTarget, 75);
    elseif DailyForecastDeficit_kWh(d) >= 8
        baseTarget = max(baseTarget, 65);
    else
        baseTarget = max(baseTarget, 60);
    end

    DailySOCTarget_percent(d) = baseTarget;
end

SOCTargetBase_percent = zeros(N,1);
for d = 1:D
    SOCTargetBase_percent(dateOnly == uniqueDays(d)) = DailySOCTarget_percent(d);
end

%% =========================================================
% 7) FINAL CLOUD EMS CONTROL LOOP
%% =========================================================

E_batt_kWh = SOC_initial_percent/100 * E_batt_nominal_kWh;

SOC_percent = zeros(N,1);
SOC_target_percent = zeros(N,1);

P_pv_to_load_kW = zeros(N,1);
P_pv_charge_kW = zeros(N,1);
P_batt_kW = zeros(N,1);           % positive = discharge, negative = charge
P_grid_to_load_kW = zeros(N,1);
P_grid_charge_kW = zeros(N,1);
P_curtail_kW = zeros(N,1);

LoadShedding_kW = zeros(N,1);
UnservedLoad_kW = zeros(N,1);

PVReturnLookAheadActive = false(N,1);
GridChargeSuppressedByLookAhead = false(N,1);
GridChargeAllowed = false(N,1);
FaultAwareMode = false(N,1);
EmergencyMode = false(N,1);

% Internal cloud alert outputs.
% These are alert-ready fields saved in CLOUD_HEMS_Decisions.csv.
% They can later be connected to dashboard, SMS, email, or mobile notifications.
SOC_Alert_Level = strings(N,1);
SOC_Alert_Level(:) = "Normal";

Fault_Alert_Type = strings(N,1);
Fault_Alert_Type(:) = "No Fault";

EMS_Alert_Message = strings(N,1);
EMS_Alert_Message(:) = "Normal operation";

% Optional cooperative outputs
P_transfer_to_slave_sent_kW = zeros(N,1);
P_transfer_to_slave_delivered_kW = zeros(N,1);

for t = 1:N

    capFactor = max(0.50, min(BatteryCapacityFactor(t), 1.00));
    E_batt_max_physical = E_batt_nominal_kWh * capFactor;

    SOC_now_percent = 100 * E_batt_kWh / max(E_batt_max_physical, eps);
    SOC_now_percent = max(0, min(100, SOC_now_percent));

    faultMode = DetectedFaultLabel(t);
    FaultAwareMode(t) = faultMode;

    % Select target and limits
    if faultMode
        SOC_min_current_percent = SOC_min_fault_percent;
        target_percent = max(SOCTargetBase_percent(t), SOC_target_fault_percent);
        P_batt_max = P_batt_max_fault_kW;
        P_grid_charge_max = P_grid_charge_fault_kW;
    else
        SOC_min_current_percent = SOC_min_normal_percent;
        target_percent = SOCTargetBase_percent(t);
        P_batt_max = P_batt_max_normal_kW;
        P_grid_charge_max = P_grid_charge_normal_kW;
    end

    % High grid risk uses stronger preparedness
    if GridRiskLevel(t) == 3
        target_percent = max(target_percent, SOC_target_highRisk_percent);
        P_grid_charge_max = max(P_grid_charge_max, P_grid_charge_emergency_kW);
    end

    % Specific fault adjustments
    if F5_BatteryCapacity_Detected(t)
        SOC_min_current_percent = max(SOC_min_current_percent, 35);
        target_percent = max(target_percent, 82);
        P_batt_max = min(P_batt_max, 3.0);
    end

    if F2_Load_Detected(t)
        SOC_min_current_percent = max(SOC_min_current_percent, 35);
        P_batt_max = min(P_batt_max, 3.5);
    end

    if F1_PV_Detected(t) || F4_Inverter_Detected(t)
        target_percent = max(target_percent, 80);
    end

    SOC_target_percent(t) = target_percent;

    % Conservative signal use under communication fault
    if F6_Comm_Detected(t)
        load_now = max(Load_kW(t), Load_pred_kW(t));
        pv_now   = min(PV_kW(t), PV_pred_kW(t));
    else
        load_now = Load_kW(t);
        pv_now   = PV_kW(t);
    end

    % Inverter derating means PV cannot be over-trusted
    if F4_Inverter_Detected(t)
        pv_now = min(pv_now, PV_pred_kW(t) * InverterEfficiency(t));
    end

    grid_now = GridAvailable(t);

    % Hard physical bounds
    E_min = SOC_min_current_percent/100 * E_batt_max_physical;
    E_max = SOC_max_percent/100 * E_batt_max_physical;
    E_target = target_percent/100 * E_batt_max_physical;
    E_batt_kWh = max(E_min, min(E_batt_kWh, E_max));

    % Emergency controlled shedding only when grid is unavailable and SOC is low
    effective_load = load_now;
    if faultMode && ~grid_now
        currentSOC = 100 * E_batt_kWh / max(E_batt_max_physical, eps);
        if currentSOC < SOC_critical_percent
            shed = shedding_heavy_ratio * load_now;
            EmergencyMode(t) = true;
        elseif currentSOC < SOC_warning_percent
            shed = shedding_light_ratio * load_now;
            EmergencyMode(t) = true;
        else
            shed = 0;
        end
        LoadShedding_kW(t) = shed;
        effective_load = max(load_now - shed, 0);
    end

    % PV first serves load
    P_pv_to_load = min(pv_now, effective_load);
    remaining_load = effective_load - P_pv_to_load;
    pv_surplus = pv_now - P_pv_to_load;
    P_pv_to_load_kW(t) = P_pv_to_load;

    % Use PV surplus to charge battery
    charge_room_power = max(0, (E_max - E_batt_kWh) / dt_hours);
    P_pv_charge = min([pv_surplus, P_batt_max, charge_room_power]);
    E_batt_kWh = E_batt_kWh + P_pv_charge * eta_charge * dt_hours;
    P_pv_charge_kW(t) = P_pv_charge;
    pv_surplus = pv_surplus - P_pv_charge;

    % Optional cooperative sharing after local PV/battery priority
    if ENABLE_COOPERATIVE_SHARING && pv_surplus > 0
        [slaveDemand_kW, slaveSOC_percent] = getSlaveDemandOptional(T, t);
        if SOC_now_percent >= Master_SOC_reserve_percent && slaveDemand_kW > 0
            P_send = min([pv_surplus, P_transfer_max_kW, slaveDemand_kW/eta_transfer]);
            P_transfer_to_slave_sent_kW(t) = P_send;
            P_transfer_to_slave_delivered_kW(t) = eta_transfer * P_send;
            pv_surplus = pv_surplus - P_send;
        end
    end

    P_curtail_kW(t) = max(pv_surplus, 0);

    % PV insufficient: decide battery vs grid
    if remaining_load > 0
        available_discharge_power = max(0, (E_batt_kWh - E_min) / dt_hours);

        if grid_now
            if faultMode
                % Preserve battery during detected fault unless above target
                if E_batt_kWh > E_target && ~(F5_BatteryCapacity_Detected(t) || F6_Comm_Detected(t))
                    P_discharge = min([remaining_load, P_batt_max, available_discharge_power]);
                else
                    P_discharge = 0;
                end
            else
                % Normal mode: use battery if above minimum
                P_discharge = min([remaining_load, P_batt_max, available_discharge_power]);
            end

            E_batt_kWh = E_batt_kWh - (P_discharge/eta_discharge) * dt_hours;
            P_batt_kW(t) = P_batt_kW(t) + P_discharge;

            remaining_after_batt = remaining_load - P_discharge;
            P_grid_to_load_kW(t) = max(remaining_after_batt, 0);

        else
            % Grid unavailable: battery serves as much as possible
            P_discharge = min([remaining_load, P_batt_max, available_discharge_power]);

            E_batt_kWh = E_batt_kWh - (P_discharge/eta_discharge) * dt_hours;
            P_batt_kW(t) = P_batt_kW(t) + P_discharge;

            remaining_after_batt = remaining_load - P_discharge;
            UnservedLoad_kW(t) = max(remaining_after_batt, 0);
        end
    end

    % Decide whether grid charging is allowed
    isNight = hourNow(t) >= 18 || hourNow(t) < 6;
    gridChargeAllowed = false;

    if grid_now
        if faultMode || GridRiskLevel(t) >= 2
            % In fault/high-risk mode, grid charging is permitted.
            % Actual charging still occurs only if E_batt_kWh < E_target.
            gridChargeAllowed = true;
        elseif isNight
            % PV-return look-ahead suppresses unnecessary night charging
            [batteryEnoughUntilPV, ~] = checkBatteryEnoughUntilPVReturn( ...
                t, Load_pred_kW, PV_pred_kW, E_batt_kWh, E_batt_max_physical, ...
                SOC_min_current_percent, PV_return_threshold_kW, maxLookAhead_hours, ...
                reserveMargin_kWh, dt_hours);

            if batteryEnoughUntilPV && SOC_now_percent > SOC_hard_safe_percent
                gridChargeAllowed = false;
                PVReturnLookAheadActive(t) = true;
                GridChargeSuppressedByLookAhead(t) = true;
            else
                gridChargeAllowed = true;
            end
        end
    end

    % Hard safety override
    if grid_now && SOC_now_percent <= SOC_hard_safe_percent
        gridChargeAllowed = true;
    end

    GridChargeAllowed(t) = gridChargeAllowed;

    % Grid charge to target if allowed
    if gridChargeAllowed && E_batt_kWh < E_target
        grid_charge_room = max(0, (E_target - E_batt_kWh) / dt_hours);
        P_gc = min([P_grid_charge_max, grid_charge_room]);
        E_batt_kWh = E_batt_kWh + P_gc * eta_charge * dt_hours;
        P_grid_charge_kW(t) = P_gc;
        P_batt_kW(t) = P_batt_kW(t) - P_gc;
    end

    SOC_percent(t) = 100 * E_batt_kWh / max(E_batt_max_physical, eps);
    SOC_percent(t) = max(0, min(100, SOC_percent(t)));
end

%% =========================================================
% 8) INTERNAL SOC AND FAULT ALERT GENERATION
%% =========================================================
% These alerts are internal cloud-ready outputs. The controller generates
% clear alert fields that are saved to the decisions CSV and can be linked
% to any cloud notification service.
% External notifications (Telegram / Email) are dispatched in Section 8B
% when ENABLE_TELEGRAM or ENABLE_EMAIL are set to true.

for t = 1:N
    % SOC alert level
    if EmergencyMode(t)
        SOC_Alert_Level(t) = "Emergency";
    elseif SOC_percent(t) < SOC_critical_percent
        SOC_Alert_Level(t) = "Critical";
    elseif SOC_percent(t) < SOC_warning_percent
        SOC_Alert_Level(t) = "Warning";
    else
        SOC_Alert_Level(t) = "Normal";
    end

    % Fault alert type. If more than one condition is active, priority is
    % assigned from higher operational severity to lower severity.
    if ~GridAvailable(t)
        Fault_Alert_Type(t) = "Grid Outage";
    elseif F4_Inverter_Detected(t)
        Fault_Alert_Type(t) = "Inverter Derating";
    elseif F5_BatteryCapacity_Detected(t)
        Fault_Alert_Type(t) = "Battery Capacity Reduction";
    elseif F6_Comm_Detected(t)
        Fault_Alert_Type(t) = "Communication Delay/Freeze";
    elseif F1_PV_Detected(t)
        Fault_Alert_Type(t) = "PV Drop";
    elseif F2_Load_Detected(t)
        Fault_Alert_Type(t) = "Load Spike";
    else
        Fault_Alert_Type(t) = "No Fault";
    end

    % Combined dashboard-ready alert message
    if SOC_Alert_Level(t) == "Normal" && Fault_Alert_Type(t) == "No Fault"
        EMS_Alert_Message(t) = "Normal operation";
    elseif SOC_Alert_Level(t) ~= "Normal" && Fault_Alert_Type(t) == "No Fault"
        EMS_Alert_Message(t) = "SOC " + SOC_Alert_Level(t);
    elseif SOC_Alert_Level(t) == "Normal" && Fault_Alert_Type(t) ~= "No Fault"
        EMS_Alert_Message(t) = "Fault alert: " + Fault_Alert_Type(t);
    else
        EMS_Alert_Message(t) = "SOC " + SOC_Alert_Level(t) + " + Fault alert: " + Fault_Alert_Type(t);
    end
end

%% =========================================================
% 8B) EXTERNAL NOTIFICATION DISPATCH (TELEGRAM + EMAIL)
%% =========================================================
% Scans the generated alert timeline and sends external notifications
% for the first occurrence of each new alert type, subject to cooldown.
% This section is skipped automatically when both flags are false.

if ENABLE_TELEGRAM || ENABLE_EMAIL

    lastAlertTime_SOC   = datetime(1900,1,1);
    lastAlertTime_Fault = datetime(1900,1,1);
    lastAlertTime_Grid  = datetime(1900,1,1);
    cooldown = minutes(ALERT_COOLDOWN_MINUTES);

    for t = 1:N
        currentTime = time(t);

        % SOC alert (Warning / Critical / Emergency)
        if SOC_Alert_Level(t) ~= "Normal"
            if (currentTime - lastAlertTime_SOC) >= cooldown
                msg = sprintf('[HEMS] SOC Alert: %s | SOC = %.1f%% | Time: %s', ...
                    SOC_Alert_Level(t), SOC_percent(t), char(currentTime));
                sendExternalAlert(msg, ...
                    ENABLE_TELEGRAM, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ...
                    ENABLE_EMAIL, EMAIL_SENDER, EMAIL_PASSWORD, ...
                    EMAIL_RECIPIENT, EMAIL_SMTP_SERVER);
                lastAlertTime_SOC = currentTime;
            end
        end

        % Fault alert (any detected fault)
        if Fault_Alert_Type(t) ~= "No Fault" && Fault_Alert_Type(t) ~= "Grid Outage"
            if (currentTime - lastAlertTime_Fault) >= cooldown
                msg = sprintf('[HEMS] Fault Detected: %s | Time: %s', ...
                    Fault_Alert_Type(t), char(currentTime));
                sendExternalAlert(msg, ...
                    ENABLE_TELEGRAM, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ...
                    ENABLE_EMAIL, EMAIL_SENDER, EMAIL_PASSWORD, ...
                    EMAIL_RECIPIENT, EMAIL_SMTP_SERVER);
                lastAlertTime_Fault = currentTime;
            end
        end

        % Grid outage alert (separate cooldown)
        if ~GridAvailable(t)
            if (currentTime - lastAlertTime_Grid) >= cooldown
                msg = sprintf('[HEMS] Grid Outage Detected | Risk Level: %d | Time: %s', ...
                    GridRiskLevel(t), char(currentTime));
                sendExternalAlert(msg, ...
                    ENABLE_TELEGRAM, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ...
                    ENABLE_EMAIL, EMAIL_SENDER, EMAIL_PASSWORD, ...
                    EMAIL_RECIPIENT, EMAIL_SMTP_SERVER);
                lastAlertTime_Grid = currentTime;
            end
        end
    end

    fprintf('\n[Alerts] External notification dispatch complete.\n');
else
    fprintf('\n[Alerts] External notifications disabled (ENABLE_TELEGRAM=false, ENABLE_EMAIL=false).\n');
    fprintf('[Alerts] Internal alert fields saved to Decisions CSV.\n');
end

%% =========================================================
% 9) SAVE DECISIONS AND SUMMARY
%% =========================================================

TotalGridImport_kW = P_grid_to_load_kW + P_grid_charge_kW;

Decisions = table( ...
    time, ...
    Load_kW, PV_kW, Load_pred_kW, PV_pred_kW, ...
    GridAvailable, GridRiskLevel, ...
    DetectedFaultLabel, DetectedFaultType, ...
    F1_PV_Detected, F2_Load_Detected, F3_Grid_Detected, ...
    F4_Inverter_Detected, F5_BatteryCapacity_Detected, F6_Comm_Detected, ...
    SOC_percent, SOC_target_percent, ...
    P_pv_to_load_kW, P_pv_charge_kW, P_batt_kW, ...
    P_grid_to_load_kW, P_grid_charge_kW, TotalGridImport_kW, ...
    LoadShedding_kW, UnservedLoad_kW, ...
    GridChargeAllowed, PVReturnLookAheadActive, GridChargeSuppressedByLookAhead, FaultAwareMode, EmergencyMode, ...
    SOC_Alert_Level, Fault_Alert_Type, EMS_Alert_Message, ...
    P_transfer_to_slave_sent_kW, P_transfer_to_slave_delivered_kW, ...
    'VariableNames', { ...
    'Time', ...
    'Load_kW','PV_kW','Load_pred_kW','PV_pred_kW', ...
    'GridAvailable','GridRiskLevel', ...
    'DetectedFaultLabel','DetectedFaultType', ...
    'F1_PV_Drop_Detected','F2_Load_Spike_Detected','F3_Grid_Outage_Detected', ...
    'F4_Inverter_Detected','F5_BatteryCapacity_Detected','F6_Communication_Detected', ...
    'SOC_percent','SOC_Target_percent', ...
    'PV_to_Load_kW','PV_to_Battery_kW','BatteryPower_kW', ...
    'Grid_to_Load_kW','Grid_Charge_kW','TotalGridImport_kW', ...
    'LoadShedding_kW','UnservedLoad_kW', ...
    'GridChargeAllowed','PVReturnLookAheadActive','GridChargeSuppressedByLookAhead','FaultAwareMode','EmergencyMode', ...
    'SOC_Alert_Level','Fault_Alert_Type','EMS_Alert_Message', ...
    'TransferToSlave_Sent_kW','TransferToSlave_Delivered_kW'});

writetable(Decisions, decisionFile);

LoadEnergy_kWh = sum(Load_kW) * dt_hours;
PVEnergy_kWh = sum(PV_kW) * dt_hours;
GridToLoad_kWh = sum(P_grid_to_load_kW) * dt_hours;
GridCharging_kWh = sum(P_grid_charge_kW) * dt_hours;
TotalGridImport_kWh = sum(TotalGridImport_kW) * dt_hours;
BatteryCharge_kWh = sum(max(-P_batt_kW,0)) * dt_hours;
BatteryDischarge_kWh = sum(max(P_batt_kW,0)) * dt_hours;
LoadShedding_kWh = sum(LoadShedding_kW) * dt_hours;
UnservedLoad_kWh = sum(UnservedLoad_kW) * dt_hours;
ServedLoad_percent = 100 * (LoadEnergy_kWh - UnservedLoad_kWh) / max(LoadEnergy_kWh, eps);

Metric = [
    "Load Energy (kWh)";
    "PV Energy (kWh)";
    "Grid-to-Load Energy (kWh)";
    "Grid Charging Energy (kWh)";
    "Total Grid Import (kWh)";
    "Battery Charge Energy (kWh)";
    "Battery Discharge Energy (kWh)";
    "Load Shedding Energy (kWh)";
    "Unserved Load Energy (kWh)";
    "Served Load (%)";
    "Final SOC (%)";
    "Minimum SOC (%)";
    "Maximum SOC (%)";
    "Fault Mode Samples";
    "Fault Mode Hours";
    "PV-Return Look-Ahead Active Samples";
    "Grid Charge Suppressed by Look-Ahead Samples";
    "Emergency Mode Samples";
    "Energy-Criticality Grid Risk Enabled";
    "Criticality Percentile";
    "Criticality Max Weight";
    "Trend Detection Enabled";
    "Trend Increase Factor";
    "Recovery Bonus Enabled";
    "Recovery Stable Hours";
    "SOC Warning Samples";
    "SOC Critical Samples";
    "SOC Emergency Samples";
    "Any Fault Alert Samples";
    "Average Grid Risk Level"
];

Value = [
    LoadEnergy_kWh;
    PVEnergy_kWh;
    GridToLoad_kWh;
    GridCharging_kWh;
    TotalGridImport_kWh;
    BatteryCharge_kWh;
    BatteryDischarge_kWh;
    LoadShedding_kWh;
    UnservedLoad_kWh;
    ServedLoad_percent;
    SOC_percent(end);
    min(SOC_percent);
    max(SOC_percent);
    sum(FaultAwareMode);
    sum(FaultAwareMode)*dt_hours;
    sum(PVReturnLookAheadActive);
    sum(GridChargeSuppressedByLookAhead);
    sum(EmergencyMode);
    double(USE_ENERGY_CRITICALITY_GRID_RISK);
    criticalityPercentile;
    criticalityMaxWeight;
    double(USE_GRID_RISK_TREND_DETECTION);
    trendIncreaseFactor;
    double(USE_GRID_RISK_RECOVERY_BONUS);
    recoveryStableHours;
    sum(SOC_Alert_Level == "Warning");
    sum(SOC_Alert_Level == "Critical");
    sum(SOC_Alert_Level == "Emergency");
    sum(Fault_Alert_Type ~= "No Fault");
    mean(GridRiskLevel)
];

Summary = table(Metric, Value);

% Store the offline validation pattern as table custom metadata for traceability.
% The CSV file itself remains a simple Metric/Value table for easy reading.
Summary.Properties.Description = sprintf('Cloud grid-history pattern: %s | Adaptive energy-criticality grid risk with SOC/fault alerts: %d | trend: %d | recovery: %d', string(CLOUD_GRID_HISTORY_PATTERN), USE_ENERGY_CRITICALITY_GRID_RISK, USE_GRID_RISK_TREND_DETECTION, USE_GRID_RISK_RECOVERY_BONUS);

writetable(Summary, summaryFile);

disp(' ');
disp('================ CLOUD HEMS SUMMARY ================');
disp(Summary);

fprintf('\nSaved cloud EMS outputs in folder:\n');
fprintf('  %s\n', outputFolder);
fprintf('  %s\n', decisionFile);
fprintf('  %s\n', summaryFile);

%% =========================================================
% 10) FIGURES
%% =========================================================

figure('Position',[100 100 1200 600]);
plot(time, SOC_percent, 'LineWidth', 1.4); hold on;
plot(time, SOC_target_percent, '--', 'LineWidth', 1.2);
yline(SOC_min_normal_percent, ':', 'Normal SOC min');
yline(SOC_hard_safe_percent, ':', 'Hard safe SOC');
xlabel('Time');
ylabel('SOC (%)');
title('Cloud HEMS Battery SOC and Dynamic Target');
legend('SOC','SOC Target','Location','best');
grid on;
exportgraphics(gcf, fullfile(outputFolder, 'Fig_CLOUD_HEMS_SOC.png'), 'Resolution', 300);

figure('Position',[100 100 1200 600]);
plot(time, Load_kW, 'LineWidth', 1.1); hold on;
plot(time, PV_kW, 'LineWidth', 1.1);
plot(time, TotalGridImport_kW, 'LineWidth', 1.1);
plot(time, P_batt_kW, 'LineWidth', 1.1);
xlabel('Time');
ylabel('Power (kW)');
title('Cloud HEMS Power Balance');
legend('Load','PV','Grid Import','Battery Power (+ discharge, - charge)','Location','best');
grid on;
exportgraphics(gcf, fullfile(outputFolder, 'Fig_CLOUD_HEMS_PowerBalance.png'), 'Resolution', 300);

figure('Position',[100 100 1200 600]);
stairs(time, GridRiskLevel, 'LineWidth', 1.5); hold on;
stairs(time, double(DetectedFaultLabel)*3, '--', 'LineWidth', 1.2);
stairs(time, double(GridChargeSuppressedByLookAhead)*2, ':', 'LineWidth', 1.4);
xlabel('Time');
ylabel('Level / Flag');
title('Cloud HEMS Adaptive Energy-Criticality Grid Risk, Fault Detection, and PV-Return Suppression');
legend('Grid Risk Level','Detected Fault x3','Grid Charge Suppressed by Look-Ahead x2','Location','best');
ylim([-0.1 3.3]);
grid on;
exportgraphics(gcf, fullfile(outputFolder, 'Fig_CLOUD_HEMS_RiskFaultFlags.png'), 'Resolution', 300);

fprintf('\nSaved figures in folder:\n');
fprintf('  %s\n', fullfile(outputFolder, 'Fig_CLOUD_HEMS_SOC.png'));
fprintf('  %s\n', fullfile(outputFolder, 'Fig_CLOUD_HEMS_PowerBalance.png'));
fprintf('  %s\n', fullfile(outputFolder, 'Fig_CLOUD_HEMS_RiskFaultFlags.png'));

%% =========================================================
% LOCAL FUNCTIONS
%% =========================================================


function GridAvailable = simulateGridHistoryForCloudTest(time, pattern)
    % Offline cloud-test utility.
    % This creates historical GridAvailable behavior so the no-leakage
    % learned grid-risk module can be tested without real grid outage data.
    % In real deployment, disable SIMULATE_GRID_HISTORY_FOR_CLOUD_TEST.

    N = numel(time);
    GridAvailable = true(N,1);

    pattern = string(pattern);

    switch pattern
        case "stable"
            GridAvailable(:) = true;

        case "2off_2on"
            % Repeating 4-hour cycle: 2 hours OFF, 2 hours ON
            for i = 1:N
                h = hour(time(i)) + minute(time(i))/60 + second(time(i))/3600;
                phase = mod(h, 4);
                GridAvailable(i) = phase >= 2;
            end

        case "mostly_available"
            % Mostly available grid: 1 hour OFF, 5 hours ON
            % Repeating 6-hour cycle. This represents a relatively stable grid.
            for i = 1:N
                h = hour(time(i)) + minute(time(i))/60 + second(time(i))/3600;
                phase = mod(h, 6);
                GridAvailable(i) = phase >= 1;
            end

        case "mostly_outage"
            % Mostly outage grid: 5 hours OFF, 1 hour ON
            % Repeating 6-hour cycle. This represents a highly unreliable grid.
            for i = 1:N
                h = hour(time(i)) + minute(time(i))/60 + second(time(i))/3600;
                phase = mod(h, 6);
                GridAvailable(i) = phase >= 5;
            end

        case "3off_1on"
            % Repeating 4-hour cycle: 3 hours OFF, 1 hour ON
            for i = 1:N
                h = hour(time(i)) + minute(time(i))/60 + second(time(i))/3600;
                phase = mod(h, 4);
                GridAvailable(i) = phase >= 3;
            end

        case "4off_2on"
            % Repeating 6-hour cycle: 4 hours OFF, 2 hours ON
            for i = 1:N
                h = hour(time(i)) + minute(time(i))/60 + second(time(i))/3600;
                phase = mod(h, 6);
                GridAvailable(i) = phase >= 4;
            end

        otherwise
            error('Unknown CLOUD_GRID_HISTORY_PATTERN: %s', pattern);
    end
end

function sendExternalAlert(message, useTelegram, botToken, chatID, ...
    useEmail, emailSender, emailPassword, emailRecipient, smtpServer)
% sendExternalAlert  Send an alert message via Telegram and/or Email.
%
% Both channels are attempted independently. If Telegram fails (e.g. blocked),
% Email is still sent. All errors are caught silently so the EMS never stops
% due to a notification failure.
%
% To activate:
%   Telegram: create a bot via BotFather, get token and chat ID.
%   Email   : enable 2-Step Verification in Gmail, generate an App Password.

    % --- Telegram ---
    if useTelegram
        try
            url = sprintf('https://api.telegram.org/bot%s/sendMessage', botToken);
            webwrite(url, 'chat_id', chatID, 'text', message);
            fprintf('[Alert-Telegram] Sent: %s\n', message);
        catch ME
            fprintf('[Alert-Telegram] Failed: %s. Trying Email...\n', ME.message);
            % Fall through to Email below
            useEmail = true;
        end
    end

    % --- Email ---
    if useEmail
        try
            setpref('Internet', 'SMTP_Server',   smtpServer);
            setpref('Internet', 'E_mail',         emailSender);
            setpref('Internet', 'SMTP_Username',  emailSender);
            setpref('Internet', 'SMTP_Password',  emailPassword);

            props = java.lang.System.getProperties;
            props.setProperty('mail.smtp.auth',                  'true');
            props.setProperty('mail.smtp.socketFactory.port',    '465');
            props.setProperty('mail.smtp.socketFactory.class',   ...
                'javax.net.ssl.SSLSocketFactory');

            sendmail(emailRecipient, 'HEMS Alert', message);
            fprintf('[Alert-Email] Sent: %s\n', message);
        catch ME
            fprintf('[Alert-Email] Failed: %s\n', ME.message);
        end
    end
end


function T = getLatestCloudDataPlaceholder()
    % Replace this placeholder with actual cloud ingestion.
    % Required output table columns:
    % Time, Load_kW, PV_kW, Load_pred_kW, PV_pred_kW
    error(['USE_API_INPUT is true, but getLatestCloudDataPlaceholder() ', ...
           'has not been connected to the real cloud/API source yet.']);
end

function x = getCol(T, names, N)
    x = [];
    for i = 1:numel(names)
        if any(strcmp(T.Properties.VariableNames, names{i}))
            x = T.(names{i});
            break;
        end
    end
    if isempty(x)
        error('Required column not found. Tried: %s', strjoin(names, ', '));
    end
    x = double(x);
    if numel(x) ~= N
        error('Column length mismatch.');
    end
end

function x = getColOptional(T, names, N, defaultValue)
    x = [];
    for i = 1:numel(names)
        if any(strcmp(T.Properties.VariableNames, names{i}))
            x = T.(names{i});
            break;
        end
    end
    if isempty(x)
        x = defaultValue;
    end
    x = double(x);
    if numel(x) ~= N
        error('Optional column length mismatch.');
    end
end

function h = longestTrueRunHours(flag, dt_hours)
    flag = logical(flag(:));
    if ~any(flag)
        h = 0;
        return;
    end
    d = diff([false; flag; false]);
    starts = find(d == 1);
    ends = find(d == -1) - 1;
    maxSamples = max(ends - starts + 1);
    h = maxSamples * dt_hours;
end

function sustained = movingSustain(flag, nSamples)
    flag = logical(flag(:));
    sustained = false(size(flag));
    if nSamples <= 1
        sustained = flag;
        return;
    end
    count = movsum(double(flag), [nSamples-1 0]);
    sustained = count >= nSamples;
    idx = find(sustained);
    for k = 1:numel(idx)
        startIdx = max(1, idx(k)-nSamples+1);
        sustained(startIdx:idx(k)) = true;
    end
end

function cleaned = keepLongSegments(flag, minLength)
    flag = logical(flag(:));
    cleaned = false(size(flag));
    d = diff([false; flag; false]);
    starts = find(d == 1);
    ends = find(d == -1) - 1;
    for i = 1:numel(starts)
        if (ends(i) - starts(i) + 1) >= minLength
            cleaned(starts(i):ends(i)) = true;
        end
    end
end

function [batteryEnough, horizonHours] = checkBatteryEnoughUntilPVReturn( ...
    t, Load_pred_kW, PV_pred_kW, E_batt_kWh, E_batt_max_kWh, ...
    SOC_min_current_percent, PV_return_threshold_kW, maxLookAhead_hours, ...
    reserveMargin_kWh, dt_hours)

    N = numel(Load_pred_kW);
    maxSteps = min(N-t+1, max(1, round(maxLookAhead_hours/dt_hours)));
    idxH = t:min(N, t+maxSteps-1);

    pvReturnRel = find(PV_pred_kW(idxH) >= PV_return_threshold_kW, 1, 'first');

    if isempty(pvReturnRel)
        idxUse = idxH;
    else
        idxUse = idxH(1:pvReturnRel);
    end

    horizonHours = numel(idxUse) * dt_hours;

    predictedDeficit_kWh = sum(max(Load_pred_kW(idxUse) - PV_pred_kW(idxUse), 0)) * dt_hours;
    E_min = SOC_min_current_percent/100 * E_batt_max_kWh;
    usableBattery_kWh = max(E_batt_kWh - E_min, 0);

    batteryEnough = usableBattery_kWh >= (predictedDeficit_kWh + reserveMargin_kWh);
end

function [slaveDemand_kW, slaveSOC_percent] = getSlaveDemandOptional(T, t)
    slaveDemand_kW = 0;
    slaveSOC_percent = 70;

    if any(strcmp(T.Properties.VariableNames, 'Slave_Load_kW')) && ...
       any(strcmp(T.Properties.VariableNames, 'Slave_PV_kW'))

        slaveLoad = max(double(T.Slave_Load_kW(t)), 0);
        slavePV   = max(double(T.Slave_PV_kW(t)), 0);
        slaveDemand_kW = max(slaveLoad - slavePV, 0);

        if any(strcmp(T.Properties.VariableNames, 'Slave_SOC_percent'))
            slaveSOC_percent = max(min(double(T.Slave_SOC_percent(t)), 100), 0);
        end
    end
end
