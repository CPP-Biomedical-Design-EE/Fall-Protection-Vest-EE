%% Fall vest - user-specified 5 V / 4 A solenoid
% Historical filename retained. Replaces the old servo model.
% Run the whole script; no toolboxes required.
% USER-SPECIFIED solenoid: 5 V, 4 A (20 W); exact model not yet verified.
% EDIT: This is a NEW load specification,originally modeled 12 V
% ALL OTHER numerical defaults are editable ASSUMPTIONS, not hardware data.
% Architecture assumed pending confirmation of the power bank:
% 5 V USB -> parallel branches for electronics and switched solenoid.
% A MOSFET driver and suitable flyback/clamp protection are required in the
% hardware; GPIO cannot drive the coil. Their dynamics are NOT modeled 


clear; clc; close all;

%% 1. INPUTS - replace assumptions with selected bank/driver measurements
p.USB_V = 5.0;
p.USB_limit_A = 3.5;       % OLD hypothetical limit retained; NOT bank rating
p.source_R_ohm = 0.0;     % Assumed bank DC output resistance
p.cable_loop_R_ohm = 0.10;% Both wires + connectors, common supply path
p.warning_V = 4.75;       % Illustrative warning, not a board reset threshold
p.solenoid_V = 5;
p.solenoid_A = 4;         % User's new nominal current at 5 V
p.solenoid_R_ohm = p.solenoid_V/p.solenoid_A; % Inferred 1.25 ohm, not measured
p.solenoid_model = 'resistive'; % 'resistive' or 'constant_current_stress'
% Default: coil current decreases with applied voltage. No invented L/force/
% thermal model. Alternative constant_current_stress keeps full 4 A demand
% despite droop: conservative sensitivity bound, not a physical bare coil.
p.driver_R_ohm = 0;       % Assumed series MOSFET and local branch wiring R
p.driver_limit_A = NaN;   % Unknown; set after driver selection
p.ESP32_A = .050; p.sensor_A = .005;
p.LTE_idle_A = .020;
p.LTE_TX_A = 2.0;         % Conservative BOARD INPUT stress assumption
p.GPS_A = .030;           % Incremental; do not double-count integrated GNSS
p.buzzer_A = .030;
% Bare ESP32 and sensors require appropriate regulated rails, not 5 V pins.
% TEL0182 dedicated Power IN minimum is 5 V: check exact board input limits.
% This common-bus model does not prove board compatibility at 4.75 V.

p.capacity_mAh = [10000 15000];
p.label_cell_V = 3.7;    % Assumed label reference; use actual rated Wh if known
p.usable_bank_fraction = .80; % Bank conversion/cutoff/age allowance, assumed
% No external boost efficiency factor is applied to the direct 5 V coil.
p.requests_per_day = 24; p.falls_per_day = 1; p.target_days = 7;
p.solenoid_on_s = .5;    % EXAMPLE, not validated safe on-time or duty cycle
p.solenoid_to_TX_gap_s = .050;
p.measured_release_tail_s = NaN; % Coil decay/mechanical release unknown
p.event_start_s = 2; p.event_end_s = 6;
p.TX_duration_s = 1; p.buzzer_duration_s = 2;
p.edge_s = .005;          % Scheduling envelope, NOT coil electrical rise time
p.dt_s = .001; p.end_s = 8;
p.save_outputs = true;

names = {'ESP32 + sensor only';'Solenoid only - bench load';...
 'TEL0182 only - LTE and GPS';'Solenoid + TEL0182 - simultaneous';...
 'Fall - all loads simultaneous';'Fall - solenoid then LTE';...
 'Location request - ESP32 sensor TEL0182';...
 'Repeated activation + LTE - stress screen'};
nCases=numel(names);
% "Only" cases isolate electrical branches; real activation requires a driver.
% Cases 2-4 omit MCU load intentionally; case 5 includes it for full-system test.
% Optional per-case measurements. NaN means unknown, never zero or pass.
p.measured_ripple_Vpp=NaN(nCases,1);
p.allowed_ripple_Vpp=NaN;
p.measured_converter_input_W=NaN(nCases,1);
p.measured_converter_output_W=NaN(nCases,1);
p.minimum_efficiency_pct=NaN;
% Matched input/output measurements must be for the SAME converter and interval.
% USB charging power is not internal battery discharge input power.

assert(p.USB_V>0 && p.USB_limit_A>0 && p.solenoid_R_ohm>0);
assert(p.driver_R_ohm>=0 && p.source_R_ohm>=0 && p.cable_loop_R_ohm>=0);
assert(any(strcmp(p.solenoid_model,{'resistive','constant_current_stress'})));
assert(p.usable_bank_fraction>0 && p.usable_bank_fraction<=1);
assert(p.solenoid_on_s>0 && p.solenoid_on_s<2);
assert(p.dt_s>0 && p.edge_s>=p.dt_s);
assert(p.requests_per_day>=0 && p.falls_per_day>=0);
assert(all(p.capacity_mAh>0) && p.label_cell_V>0 && p.target_days>0);
p.seq_TX_s=p.event_start_s+p.solenoid_on_s+p.edge_s+p.solenoid_to_TX_gap_s;
assert(p.solenoid_to_TX_gap_s>=0 && p.seq_TX_s+p.TX_duration_s+p.edge_s<p.event_end_s);
assert(p.event_end_s+p.edge_s<p.end_s);
scriptPath=mfilename('fullpath');
if isempty(scriptPath), outDir=pwd; else, outDir=fileparts(scriptPath); end
outDir=fullfile(outDir,'FallVest_Solenoid5V4A_Results');
if p.save_outputs && ~exist(outDir,'dir'), mkdir(outDir); end

fprintf('USER-SPECIFIED COIL: %.1f V, %.2f A, %.2f W; inferred R = %.3f ohm\n',...
 p.solenoid_V,p.solenoid_A,p.solenoid_V*p.solenoid_A,p.solenoid_R_ohm);
fprintf('Direct 5 V supply; no external boost. Coil model: %s\n',p.solenoid_model);
fprintf('These are demands; a bank current limit can prevent operation.\n');
fprintf('All pulse lengths, source limits and driver parameters require verification.\n\n');

%% 2. TIME PROFILES AND OPERATING-POINT SCREENING
t=(0:p.dt_s:p.end_s)';
results=cell(nCases,1); profiles=cell(nCases,1);
peakNom=zeros(nCases,1); peakRequired=peakNom; minReq=peakNom;
minValid=NaN(nCases,1); overTime=peakNom; maxCoil=peakNom;
energyNom=peakNom; cableLoss=NaN(nCases,1);
allSupported=false(nCases,1); status=cell(nCases,1);
for k=1:nCases
 L=makeLoads(t,p,k); r=screenLoad(L,p); profiles{k}=L; results{k}=r;
 peakNom(k)=max(r.nominalRequired_A);
 if all(isfinite(r.required_A)), peakRequired(k)=max(r.required_A);
 else, peakRequired(k)=Inf; end
 if all(isfinite(r.unlimited_bus_V)), minReq(k)=min(r.unlimited_bus_V);
 else, minReq(k)=NaN; end
 v=r.bus_V(isfinite(r.bus_V));
 if ~isempty(v), minValid(k)=min(v); end
 overTime(k)=trapz(t,double(~r.supported));
 maxCoil(k)=max(L.coil_A);
 energyNom(k)=trapz(t,r.nominalPower_W)/3600;
 allSupported(k)=all(r.supported);
 if allSupported(k)
  cableLoss(k)=trapz(t,p.cable_loop_R_ohm*r.required_A.^2);
  if minValid(k)<p.warning_V
   status{k}='MODEL: BELOW VOLTAGE WARNING';
  else, status{k}='WITHIN ASSUMED LIMITS; HARDWARE UNVERIFIED'; end
 else, status{k}='UNSUPPORTED DEMAND: ACTUAL OVERLOAD RESPONSE UNKNOWN'; end

 fig=figure('Name',names{k},'Color','w');
 subplot(4,1,1);
 plot(t,r.unlimited_bus_V,'r--',t,r.bus_V,'b','LineWidth',1.2); hold on;
 yline(p.warning_V,'k--','Illustrative warning'); ylabel('5 V bus (V)'); grid on;
 title([names{k} ' - operating-point screening']);
 legend('Requested point, limits ignored','Within assumed limits only','Location','best');
 subplot(4,1,2);
 plot(t,r.nominalRequired_A,'k:',t,r.required_A,'r--',...
  t,r.actualSupported_A,'b','LineWidth',1.2); hold on;
 yline(p.USB_limit_A,'k--','Assumed port limit'); ylabel('USB current (A)'); grid on;
 legend('Nominal demand at rated 5 V','Demand including droop',...
  'Supported operating point only','Location','best');
 subplot(4,1,3);
 plot(t,[L.ESP_sensor,L.TEL,L.GPS,L.buzzer,r.unlimitedCoil_A],'LineWidth',1.1);
 ylabel('At 5 V input (A)'); grid on;
 legend('ESP32 sensor','LTE','GPS increment','Buzzer','Coil, limits ignored','Location','best');
 subplot(4,1,4);
 yyaxis left; plot(t,L.coil_A,'m:',t,r.unlimitedCoil_A,'m-');
 ylabel('Coil current (A)');
 yyaxis right; stairs(t,double(~r.supported),'r'); ylim([-.05 1.1]);
 ylabel('Unsupported = 1'); xlabel('Time (s)'); grid on;
 % Dotted magenta = nominal 4 A command; solid magenta = coil current
 % with droop but source limits ignored, NOT verified delivered current.
 if p.save_outputs
  trace=table(t,r.unlimited_bus_V,r.bus_V,r.required_A,r.actualSupported_A,...
   L.coil_A,r.unlimitedCoil_A,r.supportedCoil_A,r.supportedCoil_V,r.supported,...
   'VariableNames',{'Time_s','UnlimitedRequestedBus_V','SupportedBus_V',...
   'RequiredUSB_A','SupportedUSB_A','NominalCoilCommand_A',...
   'UnlimitedCoil_A','SupportedCoil_A','SupportedCoil_V','SupportedPoint'});
  writetable(trace,fullfile(outDir,sprintf('Scenario_%d.csv',k)));
  safeSave(fig,fullfile(outDir,sprintf('Scenario_%d.png',k)));
 end
end
summary=table(names,peakNom,peakRequired,minReq,minValid,overTime,maxCoil,...
 energyNom,cableLoss,allSupported,status,'VariableNames',{'Scenario',...
 'PeakNominalRated5VDemand_A','PeakRequiredUSB_A','MinUnlimitedRequestedBus_V',...
 'MinSupportedBus_V','UnsupportedDuration_s','NominalPeakCoilCommand_A',...
 'NominalRequestedEnergy_Wh','CableLossIfAllSupported_J','AllPointsWithinAssumedLimits','Status'});
fprintf('\nSCENARIO SUMMARY - demanded current is not necessarily delivered\n'); disp(summary);

%% 3. FALL TIMING COMPARISON
A=profiles{5}; B=profiles{6};
assert(~any(B.coil_A>1e-9 & B.TX_fraction>1e-9),'Sequential command overlap.');
for f={'ESP_sensor','TEL','GPS','buzzer','coil_A'}
 field=f{1};
 assert(abs(trapz(t,A.(field))-trapz(t,B.(field)))<1e-8,...
  'Nominal component current-time commands must match between fall cases.');
end
fallComparison=summary([5 6],:);
fallComparison.TXDelay_s=[0;p.seq_TX_s-p.event_start_s];
fprintf('\nSEQUENTIAL COMPARISON: command pulses do not overlap.\n');
fprintf('Coil current decay and mechanical release are NOT verified by this model.\n');
disp(fallComparison);
fig=figure('Name','Solenoid fall timing comparison','Color','w');
subplot(3,1,1);
plot(t,results{5}.required_A,t,results{6}.required_A,'LineWidth',1.2); hold on;
yline(p.USB_limit_A,'k--','Assumed port limit'); grid on; ylabel('Required USB A');
legend('Simultaneous','Solenoid then LTE','Location','best');
title('Required demand, not measured/delivered current');
subplot(3,1,2);
plot(t,results{5}.unlimited_bus_V,'--',t,results{6}.unlimited_bus_V,'--');
grid on; ylabel('Unlimited bus V');
title('Hypothetical operating points ignoring limits - not overload waveforms');
subplot(3,1,3);
plot(t,A.coil_A,'k',t,A.TEL,'b',t,B.TEL,'r--');
grid on; xlabel('Time (s)'); ylabel('Branch current (A)');
legend('Nominal coil command at 5 V, both','LTE at 5 V, simultaneous',...
 'LTE at 5 V, sequential','Location','best');
if p.save_outputs, safeSave(fig,fullfile(outDir,'Fall_timing_comparison.png')); end

%% 4. STRESS SCREEN: reduced USB output, cable resistance and source limit
% USB 4.8 V is a supply-tolerance/stress case, NOT internal battery voltage.
% A true low-state-of-charge model needs bank/cell data and cutoff behavior.
% Source limit variants are hypothetical comparisons, not selected products.
% Rated-coil-current tolerance is unknown; no invented cold-coil multiplier.
q=0; sweepRows=zeros(12,7);
for voltage=[p.USB_V .96*p.USB_V]
 for cableR=[p.cable_loop_R_ohm 2*p.cable_loop_R_ohm]
  for limit=[p.USB_limit_A 5 7]
   q=q+1; ps=p; ps.USB_V=voltage; ps.cable_loop_R_ohm=cableR;
   ps.USB_limit_A=limit;
   worst=screenLoad(profiles{5},ps);
   ir=max(worst.required_A); v=min(worst.unlimited_bus_V);
   sweepRows(q,:)=[voltage cableR limit ir v all(worst.supported) ...
    all(worst.supported) && v>=p.warning_V];
  end
 end
end
stressSweep=array2table(sweepRows,'VariableNames',{'Source_V','CableLoop_ohm',...
 'AssumedSourceLimit_A','PeakRequiredUSB_A','MinUnlimitedBus_V',...
 'AllPointsWithinAssumedCurrentLimits','WithinCurrentAndWarningLimits'});
disp(stressSweep);

%% 5. ENERGY-ONLY RUNTIME: compare 10,000 and 15,000 mAh
% Uses demanded nominal 5 V power, NOT operation after an overload shutdown.
% Requests and falls are occasional events, not the repeated stress case.
% No force, travel time, heating, inductance, switching ripple or reset model.
base_W=mean(results{1}.nominalPower_W);
extraRequest=max(0,energyNom(7)-energyNom(1));
extraFall=[max(0,energyNom(5)-energyNom(1));max(0,energyNom(6)-energyNom(1))];
assert((p.requests_per_day+p.falls_per_day)*p.end_s<=86400);
runtimeRows=zeros(numel(p.capacity_mAh)*2,10); modes=cell(size(runtimeRows,1),1); q=0;
for cap=p.capacity_mAh
 for j=1:2
  q=q+1; labelWh=cap*p.label_cell_V/1000;
  usable=labelWh*p.usable_bank_fraction;
  averageW=base_W+(p.requests_per_day*extraRequest+p.falls_per_day*extraFall(j))/24;
  hours=usable/averageW; requiredWh=averageW*p.target_days*24/p.usable_bank_fraction;
  runtimeRows(q,:)=[cap labelWh usable averageW hours hours/24 ...
   hours>=24*p.target_days requiredWh requiredWh/p.label_cell_V*1000 ...
   allSupported(1)&&allSupported(7)&&allSupported(4+j)];
  if j==1, modes{q}='Simultaneous fall'; else, modes{q}='Sequential fall'; end
 end
end
runtime=array2table(runtimeRows,'VariableNames',{'Label_mAh','Label_Wh',...
 'AssumedUsable_Wh','AverageRequestedUSB_W','EnergyOnlyRuntime_h',...
 'EnergyOnlyRuntime_days','EnergyTargetMet','RequiredLabel_Wh',...
 'RequiredLabel_mAh','UsageCasesWithinAssumedCurrentLimits'});
runtime.FallTiming=modes;
fprintf('\nENERGY ARITHMETIC ONLY - unsupported loads may stop operation immediately\n'); disp(runtime);
fig=figure('Name','Energy estimate by bank capacity','Color','w');
bar(reshape(runtime.EnergyOnlyRuntime_days,2,[])');
set(gca,'XTick',1:numel(p.capacity_mAh),'XTickLabel',cellstr(num2str(p.capacity_mAh(:))));
hold on; yline(p.target_days,'k--','Target'); grid on;
xlabel('Power bank label capacity (mAh at assumed 3.7 V)'); ylabel('Energy-only days');
legend('Simultaneous fall','Sequential fall','Location','best');

%% 6. REQUIREMENTS TRACKER - measured ripple / efficiency stay unknown by default
rippleStatus=repmat({'MEASUREMENT NEEDED'},nCases,1);
efficiencyStatus=rippleStatus; measuredEta=NaN(nCases,1);
for k=1:nCases
 if isfinite(p.measured_ripple_Vpp(k)) && p.measured_ripple_Vpp(k)>=0
  rippleStatus{k}=checkLimit(p.measured_ripple_Vpp(k),p.allowed_ripple_Vpp,false);
 end
 pin=p.measured_converter_input_W(k); pout=p.measured_converter_output_W(k);
 if isfinite(pin)&&isfinite(pout)
  if pin>0&&pout>=0&&pout<=pin
   measuredEta(k)=100*pout/pin;
   efficiencyStatus{k}=checkLimit(measuredEta(k),p.minimum_efficiency_pct,true);
  else, efficiencyStatus{k}='INVALID MATCHED POWER DATA'; end
 end
end
requirements=table(names,status,p.measured_ripple_Vpp,measuredEta,...
 rippleStatus,efficiencyStatus,repmat({'VERIFY ON-TIME / DUTY / COIL RELEASE'},nCases,1),...
 repmat({'SOURCE AND DRIVER UNVERIFIED; CHECK AUTO-OFF'},nCases,1),...
 'VariableNames',{'Scenario','PowerScreen','MeasuredRipple_Vpp',...
 'MeasuredEfficiency_pct','RippleStatus','EfficiencyStatus','SolenoidTiming','HardwareStatus'});
disp(requirements);
fprintf(['IMPORTANT: 5 V x 4 A = 20 W nominal solenoid demand; no external boost.\n' ...
 'At ideal 5 V: all-on demand 6.115 A; sequential peak 4.135 A with defaults.\n' ...
 'A higher current rating alone does not remove cable voltage drop.\n' ...
 'Increasing mAh affects energy, not the port/driver current capability.\n' ...
 'Lower coil voltage lowers resistive current, not proof of enough force.\n' ...
 'Pulse duration .5 s is provisional; verify duty/thermal limits.\n']);
if p.save_outputs
 writetable(summary,fullfile(outDir,'Scenario_summary.csv'));
 writetable(fallComparison,fullfile(outDir,'Fall_timing_comparison.csv'));
 writetable(stressSweep,fullfile(outDir,'Stress_sweep.csv'));
 writetable(runtime,fullfile(outDir,'Runtime_estimate.csv'));
 writetable(requirements,fullfile(outDir,'Requirement_status.csv'));
 safeSave(fig,fullfile(outDir,'Runtime_capacity_comparison.png'));
 save(fullfile(outDir,'Model_results.mat'),'p','t','profiles','results',...
  'summary','fallComparison','stressSweep','runtime','requirements');
 fprintf('Results saved to %s\n',outDir);
end

%% LOCAL FUNCTIONS
function y=pulse(t,s,e,edge)
y=max(0,min(1,(t-s)/edge))-max(0,min(1,(t-e)/edge));
end
function L=makeLoads(t,p,k)
z=zeros(size(t)); L.ESP_sensor=z; L.TEL=z; L.GPS=z; L.buzzer=z;
L.coil_A=z; L.TX_fraction=z;
if ismember(k,[1 5 6 7 8]), L.ESP_sensor(:)=p.ESP32_A+p.sensor_A; end
if ismember(k,[2 4 5 6])
 L.coil_A=p.solenoid_A*pulse(t,2,2+p.solenoid_on_s,p.edge_s);
elseif k==8
 for s=[2 4 6]
  L.coil_A=L.coil_A+p.solenoid_A*pulse(t,s,s+p.solenoid_on_s,p.edge_s);
 end
end
if ismember(k,[3 4 5 6 7 8])
 if k==6, txStart=p.seq_TX_s; elseif k==7, txStart=4; else, txStart=2; end
 if k==8, txEnd=7; else, txEnd=txStart+p.TX_duration_s; end
 if k==8, activeEnd=7.2; else, activeEnd=p.event_end_s; end
 active=pulse(t,p.event_start_s,activeEnd,p.edge_s);
 L.TX_fraction=pulse(t,txStart,txEnd,p.edge_s);
 L.TEL=p.LTE_idle_A*active+(p.LTE_TX_A-p.LTE_idle_A)*L.TX_fraction;
 L.GPS=p.GPS_A*active;
end
if ismember(k,[5 6 8])
 L.buzzer=p.buzzer_A*pulse(t,2,2+p.buzzer_duration_s,p.edge_s);
end
end
function r=screenLoad(L,p)
% Direct 5 V coil model. L.coil_A is nominal rated-current command envelope.
% Resistive case: G = command/(Rcoil+Rdriver);
% Vbus = Vs - Rcommon*(Ielectronics + G*Vbus).
% This is an operating-point model: no inductance, decay or heating dynamics.
direct=L.ESP_sensor+L.TEL+L.GPS+L.buzzer;
cmd=L.coil_A/p.solenoid_A;
R=p.source_R_ohm+p.cable_loop_R_ohm;
if strcmp(p.solenoid_model,'resistive')
 g=cmd/(p.solenoid_R_ohm+p.driver_R_ohm);
 v=(p.USB_V-R*direct)./(1+R*g);
 icoil=g.*v;
else
 icoil=L.coil_A;
 v=p.USB_V-R*(direct+icoil);
end
ir=direct+icoil;
supported=isfinite(v) & v>0 & ir>=0 & ir<=p.USB_limit_A;
if isfinite(p.driver_limit_A), supported=supported & icoil<=p.driver_limit_A; end
r.unlimited_bus_V=v; r.required_A=ir; r.supported=supported;
r.unlimitedCoil_A=icoil;
r.bus_V=v; r.bus_V(~supported)=NaN;
r.actualSupported_A=ir; r.actualSupported_A(~supported)=NaN;
r.supportedCoil_A=icoil; r.supportedCoil_A(~supported)=NaN;
r.supportedCoil_V=(v-p.driver_R_ohm*icoil).*double(cmd>0);
r.supportedCoil_V(~supported)=NaN;
% Nominal rated-5-V demand retained for consistent energy and timing comparison.
% Runtime is an energy budget at nominal conditions, not a force/operation claim.
r.nominalRequired_A=direct+L.coil_A;
r.nominalPower_W=p.solenoid_V*(L.coil_A+direct);
% Gaps deliberately avoid inventing bank foldback/shutdown waveforms.
end
function s=checkLimit(x,lim,isMin)
if ~isfinite(lim), s='MEASURED; LIMIT NOT SET';
elseif (isMin&&x>=lim)||(~isMin&&x<=lim), s='MEASURED: WITHIN LIMIT';
else, s='MEASURED: OUTSIDE LIMIT'; end
end
function safeSave(h,path)
if ~isgraphics(h,'figure'), return; end
try, exportgraphics(h,path,'Resolution',180);
catch
 try, print(h,path,'-dpng','-r180');
 catch err, warning('Figure export skipped: %s',err.message); end
end
end

