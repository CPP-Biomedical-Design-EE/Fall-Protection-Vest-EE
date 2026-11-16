%% Fall vest: four scenarios + fall timing comparison (plain MATLAB)
% NEW architecture: regulated 5 V USB output, no external 7.4 V battery/buck.
% All numerical defaults are ILLUSTRATIVE assumptions, NOT measurements or
% manufacturer specifications. Replace them before making design claims.


clear; clc; close all;

%% 1. EDIT THESE ASSUMPTIONS
p.USB_V = 5.0;                 % Measured/selected USB voltage, V
p.USB_limit_A = 3.5;           % HYPOTHETICAL 5 V port limit, NOT a bank spec
% With 2 A LTE + 1 A servo + electronics, demand exceeds 3 A. Do not assume
% a common 5 V/3 A bank passes. Verify a bank/cable with sufficient 5 V output;
% a high wattage rating at 9/12/20 V does not imply this current at 5 V.
p.response_s = 0.0002;         % Assumed current-control response time
p.control_R_ohm = 0.15;        % Assumed voltage-feedback droop gain
p.output_C_F = 2200e-6;        % EFFECTIVE source/bus capacitor assumption
p.cap_ESR_ohm = 0.03;          % Capacitor ESR assumption
p.cable_loop_R_ohm = 0.10;     % Total positive + return cable/contact R
% C above is a model parameter, not an instruction to add this capacitor to
% USB. Check allowed inrush and actual bank stability before adding bulk C.

% Equivalent currents drawn FROM THE 5 V BUS, including board regulation.
p.ESP32_A = 0.050;
p.sensor_A = 0.005;
p.other_always_on_A = 0.0;     % Add LEDs, converters, etc. if present
p.LTE_off_A = 0.0;             % Assumes module can actually be powered off
p.LTE_idle_A = 0.020;
p.LTE_TX_A = 2.0;              % STRESS ASSUMPTION: replace with board data
p.GPS_A = 0.030;               % Incremental GPS/GNSS current; avoid counting
                              % twice if LTE current already includes GNSS
p.servo_idle_A = 0.0;          % Assumes servo power is switched OFF at rest
% If servo remains powered, replace with measured idle current (e.g. an
% assumed 0.020 A). Case 1 would then include that standby load as well.
p.servo_active_A = 1.0;        % Assumed startup/stall stress current
p.buzzer_A = 0.030;
p.warning_V = 4.75;            % Illustrative 5 V bus warning, not reset spec
% Check EACH board's input minimum separately. TEL0182 Power IN is specified
% from 5 V: a nominal 5 V bank plus cable drop needs hardware verification.

% Hypothetical bank label and usage schedule for runtime ESTIMATE ONLY.
p.label_capacity_mAh = 10000;
p.label_cell_V = 3.7;          % Capacity label reference voltage, NOT USB 5 V
p.usable_USB_energy_fraction = 0.80; % Combined conversion/cutoff/age allowance
p.requests_per_day = 24;       % Example: one request/hour
p.falls_per_day = 1;           % Example only
p.target_days = 7;

% OPTIONAL MEASUREMENTS: monitoring / request / simultaneous / sequential.
% Leave unknown values as NaN: missing measurements are NOT zero or a pass.
% Ripple must come from a steady-state oscilloscope capture that separates
% switching ripple from the load-step voltage dip. Document bandwidth/probe.
p.measured_ripple_Vpp = NaN(4,1);
p.allowed_ripple_Vpp = NaN;    % Set the team's agreed ripple limit
% Converter efficiency requires matched average input/output power measured
% over the SAME interval, at the INTERNAL converter input and output.
% A USB meter alone measures output; charging power is not discharge input.
% Do not open a sealed bank just to fill these values.
p.measured_converter_input_W = NaN(4,1);
p.measured_converter_output_W = NaN(4,1);
p.minimum_converter_efficiency_pct = NaN;
% Optional internal converter input voltage/current measurements, separate
% from USB output and load input. Averaging V and I separately does NOT give
% accurate mean power for a changing load; use mean(V.*I) for power above.
p.measured_internal_input_V = NaN(4,1);
p.measured_internal_input_A = NaN(4,1);

% Each event uses the complete timing below. Include network attachment,
% GPS acquisition and retries in realistic durations; these can take longer.
p.dt_s = 0.00005;
p.end_s = 8;
p.event_start_s = 2;
p.event_end_s = 6;
p.request_TX_start_s = 4;
p.TX_duration_s = 1;
p.servo_duration_s = 0.5;
p.buzzer_duration_s = 2;
p.edge_s = 0.005;              % Smooth load edges, 5 ms
p.servo_to_LTE_gap_s = 0.050;  % Wait AFTER servo's full falling ramp ends
% Servo returns to idle at start + duration + edge; TX then waits this gap.
% Only TX is delayed: LTE standby, GPS and buzzer timing stays identical.
% This assumes no servo holding current above servo_idle_A after motion.
p.save_outputs = true;

assert(p.USB_V>0 && p.USB_limit_A>0 && p.output_C_F>0);
assert(p.dt_s <= p.response_s/4, 'Reduce dt_s for the source response time.');
assert(p.usable_USB_energy_fraction>0 && p.usable_USB_energy_fraction<=1);
assert(p.target_days>0);
assert(p.requests_per_day>=0 && p.falls_per_day>=0);
assert(all(isnan(p.measured_ripple_Vpp) | p.measured_ripple_Vpp>=0));
assert(isnan(p.allowed_ripple_Vpp) || p.allowed_ripple_Vpp>=0);
assert(isnan(p.minimum_converter_efficiency_pct) || ...
    (p.minimum_converter_efficiency_pct>=0 && p.minimum_converter_efficiency_pct<=100));
assert(p.event_end_s + p.edge_s < p.end_s);
assert(p.event_start_s + max([p.TX_duration_s,p.servo_duration_s,...
    p.buzzer_duration_s]) <= p.event_end_s);
assert(p.request_TX_start_s >= p.event_start_s && ...
    p.request_TX_start_s+p.TX_duration_s <= p.event_end_s);
assert(p.servo_to_LTE_gap_s>=0);
p.sequential_TX_start_s = p.event_start_s+p.servo_duration_s+...
    p.edge_s+p.servo_to_LTE_gap_s;
assert(p.sequential_TX_start_s+p.TX_duration_s<=p.event_end_s,...
    'Extend event_end_s/end_s to fit the delayed LTE burst.');

scriptPath = mfilename('fullpath');
if isempty(scriptPath), outDir = pwd; else, outDir = fileparts(scriptPath); end
outDir = fullfile(outDir,'FallVest_PowerBank_Results');
if p.save_outputs && ~exist(outDir,'dir'), mkdir(outDir); end

%% 2. RUN FOUR CASES
t = (0:p.dt_s:p.end_s)';
names = {'Monitoring'; 'Location request'; 'Fall - simultaneous';...
    'Fall - servo then LTE'};
nCases = numel(names);
results = cell(nCases,1);
loadProfiles = cell(nCases,1);
fprintf('ILLUSTRATIVE MODEL: replace defaults with measured values.\n');
fprintf('No external buck converter is modeled; power bank regulates USB.\n\n');

for k = 1:nCases
    loads = makeLoads(t,p,k);
    r = simulateUSB(t,loads,p);
    results{k} = r;
    loadProfiles{k} = loads;
    if k==1
        summary = table(names(k),mean(r.load_A),max(r.load_A),...
            mean(r.source_A),max(r.source_A),min(r.device_V),...
            min(r.usb_V),p.USB_V-min(r.device_V),...
            mean(r.usb_V.*r.source_A),...
            any(r.limitActive),any(r.device_V<p.warning_V),...
            'VariableNames',{'Scenario','MeanLoad_A','PeakLoad_A',...
            'MeanUSBSource_A','PeakUSBSource_A','MinDevice_V','MinUSB_V',...
            'DeviceDropFrom5V_V','MeanUSBOutput_W','CurrentLimitReached',...
            'BelowWarningVoltage'});
    else
        summary(k,:) = {names{k},mean(r.load_A),max(r.load_A),...
            mean(r.source_A),max(r.source_A),min(r.device_V),...
            min(r.usb_V),p.USB_V-min(r.device_V),...
            mean(r.usb_V.*r.source_A),...
            any(r.limitActive),any(r.device_V<p.warning_V)};
    end

    fig = figure('Name',names{k},'Color','w');
    subplot(3,1,1);
    plot(t,r.usb_V,'b',t,r.device_V,'r','LineWidth',1.2); hold on;
    yline(p.warning_V,'k--','Illustrative warning');
    ylabel('Voltage (V)'); grid on;
    legend('At USB port','At load distribution point','Location','best');
    title([names{k} ' - assumed power-bank model']);
    subplot(3,1,2);
    plot(t,r.load_A,'r',t,r.source_A,'b','LineWidth',1.2); hold on;
    yline(p.USB_limit_A,'k--','Source limit');
    ylabel('Current (A)'); grid on;
    legend('Load demand','USB source current','Location','best');
    subplot(3,1,3);
    plot(t,[loads.ESP_sensor,loads.LTE,loads.GPS,loads.servo,loads.buzzer]);
    xlabel('Time (s)'); ylabel('Load (A)'); grid on;
    legend('ESP32 + sensors','LTE','GPS increment','Servo','Buzzer',...
        'Location','best');

    if p.save_outputs
        trace = table(t,r.usb_V,r.device_V,r.load_A,r.source_A,...
            r.cap_V,r.limitActive,'VariableNames',{'Time_s','USB_V',...
            'Device_V','Load_A','USBSource_A','Cap_V','CurrentLimitActive'});
        writetable(trace,fullfile(outDir,sprintf('Scenario_%d_trace.csv',k)));
        safeSave(fig,fullfile(outDir,sprintf('Scenario_%d.png',k)));
    end
end

%% 3. REQUIREMENTS FOR EACH SCENARIO
% The source is the bank's USB output. 'Device' is the common load input,
% not the regulated 3.3 V inside the ESP32 board. Internal input is unmodeled.
summary.MeanUSB_V = zeros(nCases,1);
summary.MaxUSB_V = zeros(nCases,1);
summary.MeanDevice_V = zeros(nCases,1);
summary.MaxDevice_V = zeros(nCases,1);
summary.USBTransientSpan_V = zeros(nCases,1);
summary.DeviceTransientSpan_V = zeros(nCases,1);
summary.CableLoss_W = zeros(nCases,1);
summary.DeviceInputPower_W = zeros(nCases,1);
summary.MeasuredRipple_Vpp = p.measured_ripple_Vpp(:);
summary.MeasuredConverterEfficiency_pct = NaN(nCases,1);
summary.MeasuredInternalInput_V = p.measured_internal_input_V(:);
summary.MeasuredInternalInput_A = p.measured_internal_input_A(:);
rippleStatus = repmat({'MEASUREMENT NEEDED'},nCases,1);
efficiencyStatus = repmat({'MEASUREMENT NEEDED'},nCases,1);
voltageStatus = repmat({'MODEL: ABOVE WARNING'},nCases,1);
currentStatus = repmat({'MODEL: WITHIN SOURCE LIMIT'},nCases,1);
for k=1:nCases
    r=results{k};
    summary.MeanUSB_V(k)=mean(r.usb_V);
    summary.MaxUSB_V(k)=max(r.usb_V);
    summary.MeanDevice_V(k)=mean(r.device_V);
    summary.MaxDevice_V(k)=max(r.device_V);
    % Full-window spans are LOAD TRANSIENTS, not switching ripple.
    summary.USBTransientSpan_V(k)=max(r.usb_V)-min(r.usb_V);
    summary.DeviceTransientSpan_V(k)=max(r.device_V)-min(r.device_V);
    summary.CableLoss_W(k)=mean(p.cable_loop_R_ohm*r.load_A.^2);
    summary.DeviceInputPower_W(k)=mean(r.device_V.*r.load_A);
    if summary.BelowWarningVoltage(k)
        voltageStatus{k}='MODEL: BELOW WARNING - INVESTIGATE';
    end
    if summary.CurrentLimitReached(k)
        currentStatus{k}='MODEL: CURRENT LIMIT REACHED';
    end
    if isfinite(p.measured_ripple_Vpp(k))
        rippleStatus{k}=checkMeasurement(p.measured_ripple_Vpp(k),...
            p.allowed_ripple_Vpp,false);
    end
    pin=p.measured_converter_input_W(k);
    pout=p.measured_converter_output_W(k);
    if isfinite(pin) && isfinite(pout)
        if pin<=0 || pout<0 || pout>pin
            efficiencyStatus{k}='INVALID POWER DATA';
        else
            eta=100*pout/pin;
            summary.MeasuredConverterEfficiency_pct(k)=eta;
            efficiencyStatus{k}=checkMeasurement(eta,...
                p.minimum_converter_efficiency_pct,true);
        end
    end
end
requirements=table(names,voltageStatus,currentStatus,rippleStatus,...
    efficiencyStatus,repmat({'VERIFY LOW-LOAD AUTO-OFF ON HARDWARE'},nCases,1),...
    repmat({'CHECK EACH BOARD INPUT LIMIT; NOT A RESET PREDICTION'},nCases,1),...
    'VariableNames',{'Scenario','VoltageCheck','CurrentCheck','SwitchingRipple',...
    'ConverterEfficiency','PowerBankAutoOff','ComponentOperation'});
disp(summary);
fprintf('\nREQUIREMENT STATUS (model results are not hardware validation)\n');
disp(requirements);

%% 3B. DIRECT FALL COMPARISON (same loads, durations and event window)
fallIDs=[3 4];
fallComparison=summary(fallIDs,{'Scenario','PeakLoad_A','PeakUSBSource_A',...
    'MinUSB_V','MinDevice_V','DeviceDropFrom5V_V','CableLoss_W',...
    'CurrentLimitReached','BelowWarningVoltage'});
fallComparison.TXStart_s=[p.event_start_s;p.sequential_TX_start_s];
fallComparison.TXDelayFromFall_s=fallComparison.TXStart_s-p.event_start_s;
fallComparison.TXEndRamp_s=fallComparison.TXStart_s+p.TX_duration_s+p.edge_s;
fallComparison.Overlap_s=zeros(2,1);
fallComparison.USBOutputEnergy_Wh=zeros(2,1);
for j=1:2
    k=fallIDs(j); L=loadProfiles{k}; r=results{k};
    overlap=(L.LTE>p.LTE_idle_A+1e-9) & (L.servo>p.servo_idle_A+1e-9);
    fallComparison.Overlap_s(j)=sum(overlap)*p.dt_s;
    fallComparison.USBOutputEnergy_Wh(j)=trapz(t,r.usb_V.*r.source_A)/3600;
end
assert(fallComparison.Overlap_s(2)==0,'Sequential servo and TX must not overlap.');
% Verify equal current-time demand for each component; scheduling is the
% only load change. Source energy can differ because cable loss depends on I^2.
for field={'ESP_sensor','LTE','GPS','servo','buzzer'}
    f=field{1};
    assert(abs(trapz(t,loadProfiles{3}.(f))-trapz(t,loadProfiles{4}.(f)))<1e-8,...
        'Fall cases must have equal component current-time demand.');
end
disp(fallComparison);
fprintf('Sequential TX begins %.3f s after fall; includes %.3f s post-servo gap.\n',...
    p.sequential_TX_start_s-p.event_start_s,p.servo_to_LTE_gap_s);
fprintf('Peak USB current reduction: %.3f A; minimum load-voltage improvement: %.3f V\n',...
    fallComparison.PeakUSBSource_A(1)-fallComparison.PeakUSBSource_A(2),...
    fallComparison.MinDevice_V(2)-fallComparison.MinDevice_V(1));
compareFig=figure('Name','Fall timing comparison','Color','w');
subplot(3,1,1);
plot(t,results{3}.device_V,t,results{4}.device_V,'LineWidth',1.2); hold on;
yline(p.warning_V,'k--','Illustrative warning');
ylabel('Load voltage (V)'); grid on;
legend(names(3:4),'Location','best'); title('Fall comparison - assumed model');
subplot(3,1,2);
plot(t,results{3}.source_A,t,results{4}.source_A,'LineWidth',1.2); hold on;
yline(p.USB_limit_A,'k--','Source limit'); ylabel('USB current (A)'); grid on;
legend(names(3:4),'Location','best');
subplot(3,1,3);
plot(t,loadProfiles{3}.servo,'k',t,loadProfiles{3}.LTE,'b',...
    t,loadProfiles{4}.LTE,'r--','LineWidth',1.2);
xlabel('Time (s)'); ylabel('Load (A)'); grid on;
legend('Servo (both cases)','LTE simultaneous','LTE sequential','Location','best');
if p.save_outputs
    safeSave(compareFig,fullfile(outDir,'Fall_timing_comparison.png'));
    writetable(fallComparison,fullfile(outDir,'Fall_timing_comparison.csv'));
end

%% 4. RUNTIME AND SEVEN-DAY ENERGY TARGET
% Energy is at the USB port, not the inaccessible internal cell terminals.
% Rated Wh should come directly from the label when available.
% Average EVENT power alone must NOT be used as all-day average power.
normal_W = mean(results{1}.usb_V.*results{1}.source_A);
request_extra_Wh = max(0,trapz(t,results{2}.usb_V.*results{2}.source_A - ...
    results{1}.usb_V.*results{1}.source_A)/3600);
fall_extra_Wh = max(0,trapz(t,results{3}.usb_V.*results{3}.source_A - ...
    results{1}.usb_V.*results{1}.source_A)/3600);
sequential_fall_extra_Wh = max(0,trapz(t,results{4}.usb_V.*results{4}.source_A - ...
    results{1}.usb_V.*results{1}.source_A)/3600);
occupied_s = (p.requests_per_day+p.falls_per_day)*p.end_s;
assert(occupied_s<=86400,'Event windows exceed a day; revise usage schedule.');
label_Wh = p.label_cell_V*p.label_capacity_mAh/1000;
usable_Wh = label_Wh*p.usable_USB_energy_fraction;
daily_Wh = normal_W*24 + p.requests_per_day*request_extra_Wh + ...
    p.falls_per_day*fall_extra_Wh;
average_USB_W = daily_Wh/24;
runtime_h = usable_Wh/average_USB_W;
sequential_average_USB_W = normal_W+(p.requests_per_day*request_extra_Wh+...
    p.falls_per_day*sequential_fall_extra_Wh)/24;
sequential_runtime_h = usable_Wh/sequential_average_USB_W;
target_h = p.target_days*24;
energyTargetMet = runtime_h>=target_h;
required_label_Wh = average_USB_W*target_h/p.usable_USB_energy_fraction;
required_label_mAh = required_label_Wh/p.label_cell_V*1000;
energyShortfall_Wh = max(0,average_USB_W*target_h-usable_Wh);
invalid = any(summary.CurrentLimitReached | summary.BelowWarningVoltage);
fprintf('\nRUNTIME ESTIMATE USING ASSUMED NORMAL-USAGE SCHEDULE\n');
fprintf('Label energy = %.2f Wh; assumed usable USB energy = %.2f Wh\n',...
    label_Wh,usable_Wh);
fprintf('Requests/day = %g; falls/day = %g\n',...
    p.requests_per_day,p.falls_per_day);
fprintf('Average USB output power = %.3f W\n',average_USB_W);
fprintf('Energy-only runtime = %.1f hours (%.2f days)\n',runtime_h,runtime_h/24);
fprintf('Using sequential fall timing instead = %.1f hours (%.2f days)\n',...
    sequential_runtime_h,sequential_runtime_h/24);
fprintf('These are ALTERNATIVE schedules, not two falls counted per event.\n');
fprintf('Average USB power budget for %.1f days = %.3f W\n',...
    p.target_days,usable_Wh/target_h);
if energyTargetMet, targetStatus='MET BY ENERGY ESTIMATE ONLY';
else, targetStatus='NOT MET BY ENERGY ESTIMATE'; end
fprintf('%.1f-day target: %s\n',p.target_days,targetStatus);
fprintf('Required label capacity under SAME assumptions: %.1f Wh / %.0f mAh at %.2f V\n',...
    required_label_Wh,required_label_mAh,p.label_cell_V);
fprintf('Usable USB energy shortfall: %.2f Wh\n',energyShortfall_Wh);
fprintf('Ripple: use measured steady-state Vpp; full-window voltage span is NOT ripple.\n');
fprintf('Efficiency: 100*matched measured output power/input power; unknown by default.\n');
if invalid
    warning(['A case reached the current limit or crossed the warning voltage. '...
        'Runtime is only energy arithmetic; successful operation is NOT established.']);
end
fprintf(['Internal battery current is not simulated. Converter efficiency is only '...
    'reported when valid matched input/output measurements are supplied.\n']);
fprintf(['Voltage dips here are averaged load transients, NOT switching ripple. '...
    'Test low-load auto-off and simultaneous LTE/servo operation on hardware.\n']);

if p.save_outputs
    writetable(summary,fullfile(outDir,'Scenario_summary.csv'));
    writetable(requirements,fullfile(outDir,'Requirement_status.csv'));
    runtime = table(label_Wh,usable_Wh,normal_W,request_extra_Wh,...
        fall_extra_Wh,average_USB_W,runtime_h,...
        'VariableNames',{'Label_Wh','AssumedUsableUSB_Wh','Monitoring_W',...
        'RequestExtra_Wh','FallExtra_Wh','AverageUSB_W','EstimatedRuntime_h'});
    runtime.Target_h=target_h;
    runtime.EnergyTargetMet=energyTargetMet;
    runtime.RequiredLabel_Wh=required_label_Wh;
    runtime.RequiredLabel_mAh=required_label_mAh;
    runtime.UsableEnergyShortfall_Wh=energyShortfall_Wh;
    runtime.OperationNotValidated=true;
    runtime.SequentialFallExtra_Wh=sequential_fall_extra_Wh;
    runtime.SequentialAverageUSB_W=sequential_average_USB_W;
    runtime.SequentialRuntime_h=sequential_runtime_h;
    runtime.SequentialEnergyTargetMet=sequential_runtime_h>=target_h;
    writetable(runtime,fullfile(outDir,'Runtime_estimate.csv'));
    fig=figure('Name','Energy runtime target','Color','w');
    bar([runtime_h/24,sequential_runtime_h/24,p.target_days]);
    set(gca,'XTick',1:3,'XTickLabel',...
        {'Simultaneous falls','Sequential falls','Target'});
    ylabel('Days'); grid on;
    title('Energy estimate only - assumed usage and usable capacity');
    safeSave(fig,fullfile(outDir,'Runtime_target.png'));
    save(fullfile(outDir,'Model_results.mat'),'p','t','results','summary',...
        'requirements','runtime','loadProfiles','fallComparison');
    fprintf('Saved outputs to: %s\n',outDir);
end

%% LOCAL FUNCTIONS
function status=checkMeasurement(value,limit,isMinimum)
if ~isfinite(limit), status='MEASURED; REQUIREMENT LIMIT NOT SET';
elseif (isMinimum && value>=limit) || (~isMinimum && value<=limit)
    status='MEASURED: WITHIN SET LIMIT';
else, status='MEASURED: OUTSIDE SET LIMIT'; end
end

function a = pulse(t,startTime,endTime,edge)
% Ramp up at startTime, ramp down at endTime; no instantaneous steps.
a = max(0,min(1,(t-startTime)/edge)) - ...
    max(0,min(1,(t-endTime)/edge));
end

function L = makeLoads(t,p,scenario)
L.ESP_sensor = (p.ESP32_A+p.sensor_A+p.other_always_on_A)*ones(size(t));
L.LTE = p.LTE_off_A*ones(size(t));
L.GPS = zeros(size(t));
L.servo = p.servo_idle_A*ones(size(t));
L.buzzer = zeros(size(t));
if scenario>=2
    active = pulse(t,p.event_start_s,p.event_end_s,p.edge_s);
    if scenario==2, txStart=p.request_TX_start_s;
    elseif scenario==4, txStart=p.sequential_TX_start_s;
    else, txStart=p.event_start_s; end
    tx = pulse(t,txStart,txStart+p.TX_duration_s,p.edge_s);
    L.LTE = L.LTE+(p.LTE_idle_A-p.LTE_off_A)*active + ...
        (p.LTE_TX_A-p.LTE_idle_A)*tx;
    L.GPS = p.GPS_A*active;
end
if scenario==3 || scenario==4
    % Servo/buzzer timing identical; scenario 4 delays only LTE transmission.
    L.servo = L.servo+(p.servo_active_A-p.servo_idle_A)*...
        pulse(t,p.event_start_s,p.event_start_s+p.servo_duration_s,p.edge_s);
    L.buzzer = p.buzzer_A*...
        pulse(t,p.event_start_s,p.event_start_s+p.buzzer_duration_s,p.edge_s);
end
L.total = L.ESP_sensor+L.LTE+L.GPS+L.servo+L.buzzer;
end

function r = simulateUSB(t,L,p)
% Averaged capacitor + bounded first-order source-current model:
%   C*dVc/dt = Isource - Iload
%   Vusb = Vc + ESR*(Isource-Iload)
%   Vdevice = Vusb - Rcable*Iload
%   dIsource/dt = (clip(Iload+(Vset-Vusb)/Rcontrol)-Isource)/tau
% Controller is illustrative, not a manufacturer power-bank model.
assert(L.total(1)<p.USB_limit_A,'Idle demand exceeds assumed source limit.');
n = numel(t); x = zeros(n,2); x(1,:) = [p.USB_V,L.total(1)];
for j=1:n-1
    h=t(j+1)-t(j); il=L.total(j); ilNext=L.total(j+1);
    ilMid=(il+ilNext)/2;
    k1=stateRate(x(j,:),il,p);
    k2=stateRate(x(j,:)+h*k1/2,ilMid,p);
    k3=stateRate(x(j,:)+h*k2/2,ilMid,p);
    k4=stateRate(x(j,:)+h*k3,ilNext,p);
    x(j+1,:)=x(j,:)+h*(k1+2*k2+2*k3+k4)/6;
end
r.cap_V=x(:,1); r.source_A=x(:,2); r.load_A=L.total;
r.usb_V=r.cap_V+p.cap_ESR_ohm*(r.source_A-r.load_A);
r.device_V=r.usb_V-p.cable_loop_R_ohm*r.load_A;
raw=r.load_A+(p.USB_V-r.usb_V)/p.control_R_ohm;
r.limitActive=raw>=p.USB_limit_A;
assert(all(isfinite(x(:))) && min(r.device_V)>0,...
    ['Model collapsed or became invalid. Reduce load/increase verified source '...
    'capacity; a real bank might shut down instead.']);
end

function dx = stateRate(x,il,p)
vu=x(1)+p.cap_ESR_ohm*(x(2)-il);
target=max(0,min(p.USB_limit_A,il+(p.USB_V-vu)/p.control_R_ohm));
dx=[(x(2)-il)/p.output_C_F,(target-x(2))/p.response_s];
end

function safeSave(h,path)
% Export failure must not stop the numerical simulation.
if ~isgraphics(h,'figure'), warning('Figure closed; skipping %s',path); return; end
try
    exportgraphics(h,path,'Resolution',180);
catch
    try
        print(h,path,'-dpng','-r180');
    catch err
        warning('Could not export figure: %s',err.message);
    end
end
end
