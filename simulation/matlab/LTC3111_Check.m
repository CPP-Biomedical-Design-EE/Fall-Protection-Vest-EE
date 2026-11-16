%% LTC3111 check for fall-vest 5 V / 4 A solenoid
% SOURCE: Analog Devices LTC3111 datasheet, pp. 1, 3, 4:
% https://www.analog.com/media/en/technical-documentation/data-sheets/3111fa.pdf
% 1.5 A continuous output at Vin >= 5 V, Vout = 5 V, PWM mode.
% 2.3/3/3.7 A min/typ/max INPUT current limit; 5.8 A internal PEAK limit.
% Input/inductor/peak current limits are NOT usable continuous output ratings.
clear; clc; close all;

%% 1. PARAMETERS
p.Vout_V=5; p.reference_output_A=1.5;
p.input_limit_min_A=2.3; p.input_limit_typ_A=3.0;
p.input_limit_max_A=3.7; p.internal_peak_limit_A=5.8;
p.USB_V=5; p.USB_limit_A=3.5; % Still hypothetical bank output limit
p.assumed_efficiency=.90; % Example for required input current, NOT measured
p.solenoid_V=5; p.solenoid_A=4; p.solenoid_R_ohm=1.25;
p.ESP32_A=.050; p.sensor_A=.005;
p.LTE_idle_A=.020; p.LTE_TX_A=2; % Board-input STRESS assumption, not TEL spec
p.GPS_A=.030; p.buzzer_A=.030;
p.solenoid_on_s=.5; p.solenoid_to_TX_gap_s=.050;
p.edge_s=.005; p.event_start_s=2; p.event_end_s=6;
p.TX_duration_s=1; p.buzzer_duration_s=2;
p.seq_TX_s=p.event_start_s+p.solenoid_on_s+p.edge_s+p.solenoid_to_TX_gap_s;
p.dt_s=.001; p.end_s=8;
p.capacitances_F=[22 470 1000 4700]*1e-6;
p.warning_V=4.75; % Illustrative limit, not proven coil pull-in threshold
p.cap_plot_C_F=1000e-6; % Ideal example; not a recommended design component
p.save_outputs=true;
assert(p.warning_V>0 && p.warning_V<p.Vout_V);
assert(p.assumed_efficiency>0 && p.assumed_efficiency<=1);
assert(p.seq_TX_s+p.TX_duration_s+p.edge_s<p.event_end_s);
path=mfilename('fullpath');
if isempty(path), outDir=pwd; else, outDir=fileparts(path); end
outDir=fullfile(outDir,'FallVest_LTC3111_Results');
if p.save_outputs && ~exist(outDir,'dir'), mkdir(outDir); end

%% 2. SAME EIGHT OPERATING CASES - LOADS AT REGULATED 5 V
t=(0:p.dt_s:p.end_s)';
names={'ESP32 + sensor';'Solenoid only';'TEL0182 only';...
 'Solenoid + TEL0182';'All loads simultaneous';'Solenoid then LTE';...
 'Location request';'Repeated solenoid + LTE'};
n=numel(names); loads=cell(n,1); demand=zeros(numel(t),n);
peak=zeros(n,1); energy=zeros(n,1);
for k=1:n
 L=makeLoads(t,p,k); loads{k}=L;
 demand(:,k)=L.ESP_sensor+L.TEL+L.GPS+L.buzzer+L.coil_A;
 peak(k)=max(demand(:,k)); energy(k)=trapz(t,p.Vout_V*demand(:,k));
end
referencePower=p.Vout_V*p.reference_output_A;
withinReference=peak<=p.reference_output_A;
sourceRequired_A=p.Vout_V*peak/(p.assumed_efficiency*p.USB_V);
sourceWithinAssumedLimit=sourceRequired_A<=p.USB_limit_A;
status=repmat({'EXCEEDS 1.5 A CONTINUOUS DESIGN REFERENCE'},n,1);
status(withinReference)={'WITHIN CURRENT REFERENCE; FULL DESIGN UNVERIFIED'};
summary=table(names,peak,p.Vout_V*peak,energy,...
 repmat(p.reference_output_A,n,1),max(0,peak-p.reference_output_A),...
 sourceRequired_A,sourceWithinAssumedLimit,withinReference,status,...
 'VariableNames',{'Scenario','PeakOutputDemand_A','PeakOutputDemand_W',...
 'RequestedEventWindowEnergy_J','ContinuousReference_A','PeakShortfall_A',...
 'RequiredInputAtAssumed5V_A','WithinAssumedSourceLimit',...
 'WithinContinuousOutputReference','Status'});
disp(summary);
fprintf('Solenoid requires %.1f W; continuous reference is %.1f W at Vin>=5 V.\n',...
 p.solenoid_V*p.solenoid_A,referencePower);
fprintf('5.8 A internal peak limit must NOT be used as an output-current rating.\n');
fprintf('This screening cannot establish a higher short-pulse output capability.\n');

fig1=figure('Name','LTC3111 deployment demand','Color','w');
subplot(2,1,1);
plot(t,demand(:,[2 5 6]),'LineWidth',1.2); hold on;
yline(p.reference_output_A,'k--','1.5 A continuous reference');
ylabel('Required 5 V output (A)'); grid on;
legend(names([2 5 6]),'Location','best');
title('Required current versus datasheet continuous design reference');
subplot(2,1,2);
bar(peak*p.Vout_V); hold on;
yline(referencePower,'r--','7.5 W reference');
set(gca,'XTick',1:n,'XTickLabel',names); xtickangle(30);
ylabel('Required peak output (W)'); grid on;

%% 3. INPUT VOLTAGE CHECK
% First two rows: illustrative USB voltage states.
% Last three rows: ALTERNATIVE raw single-cell connection, not USB bank output
% and not an instruction to bypass/open a sealed power bank.
vin=[5;4.8;4.2;3.7;3.2];
architecture={'USB nominal';'USB reduced-output stress';...
 'Alternative raw cell - full';'Alternative raw cell - nominal';...
 'Alternative raw cell - low'};
requiredSolenoidInput_A=(p.solenoid_V*p.solenoid_A)./(p.assumed_efficiency*vin);
requiredAllOnInput_A=max(demand(:,5))*p.Vout_V./(p.assumed_efficiency*vin);
inputCondition=vin>=5;
conditionText=repmat({'1.5 A GUARANTEE CONDITION NOT APPLICABLE'},numel(vin),1);
conditionText(inputCondition)={'MEETS Vin CONDITION ONLY; OUTPUT LOAD STILL TOO HIGH'};
% This input-current comparison uses ideal target regulation. It is a demand
% screen, NOT actual current after regulation fails; package/inductor thermal
% constraints and source resistance have not been modeled.
inputScreen=table(architecture,vin,requiredSolenoidInput_A,requiredAllOnInput_A,...
 requiredSolenoidInput_A>p.input_limit_min_A,...
 requiredSolenoidInput_A>p.input_limit_max_A,conditionText,...
 'VariableNames',{'Architecture','Input_V','RequiredCoilOnlyInput_A',...
 'RequiredAllOnInput_A','AboveMinSpecifiedInputLimit',...
 'AboveMaxSpecifiedInputLimit','OutputReferenceCondition'});
disp(inputScreen);

%% 4. IDEAL CAPACITOR SUPPORT - BEST-CASE ENGINEERING ILLUSTRATION
% Assume an ideal source instantly supplies 1.5 A throughout deployment.
% Coil is resistive, no L; capacitor ideal (zero ESR), precharged to 5 V.
% It supplies the deficit until 4.75 V. Stop there: no invented low-voltage
% resets, current-limit waveforms, coil force or shutdown predictions.
% Real ESR, feedback delay and source limits can shorten usable support.
capRows=zeros(numel(p.capacitances_F),6);
for j=1:numel(p.capacitances_F)
 C=p.capacitances_F(j);
 g=1/p.solenoid_R_ohm;
 veq=p.reference_output_A/g; % Coil-only equilibrium in this ideal illustration
 holdTime=C/g*log((p.Vout_V-veq)/(p.warning_V-veq));
 % Constant-4A formula is a separate conservative load assumption.
 constCurrentTime=C*(p.Vout_V-p.warning_V)/(p.solenoid_A-p.reference_output_A);
 capRows(j,:)=[C C*1e6 holdTime*1000 constCurrentTime*1000 ...
  holdTime>=p.solenoid_on_s .5*C*(p.Vout_V^2-p.warning_V^2)];
end
capSupport=array2table(capRows,'VariableNames',{'IdealCap_F','IdealCap_uF',...
 'ResistiveCoilSupport_ms','Constant4ASupport_ms','SupportsAssumedHalfSecond',...
 'UsableCapEnergy_J'});
requiredIdealC=p.solenoid_on_s*g/log((p.Vout_V-veq)/(p.warning_V-veq));
requiredConstantC=(p.solenoid_A-p.reference_output_A)*p.solenoid_on_s/...
 (p.Vout_V-p.warning_V);
fprintf('\nIDEAL COIL-ONLY CAPACITOR ILLUSTRATION, NOT an LTC3111 fault simulation\n');
disp(capSupport);
fprintf('To stay >=%.2f V for %.3f s: ideal resistive-coil C = %.3f F.\n',...
 p.warning_V,p.solenoid_on_s,requiredIdealC);
fprintf('Constant 4 A assumption requires %.3f F, excluding ESR/inrush/recharge.\n',...
 requiredConstantC);
fprintf('Capacitance arithmetic alone does not validate a reservoir-capacitor design.\n');

% Plot only the valid, near-regulation part of the ideal illustration.
C=p.cap_plot_C_F;
crossTime=C/g*log((p.Vout_V-veq)/(p.warning_V-veq));
tc=linspace(0,1.25*crossTime,1000)';
vc=veq+(p.Vout_V-veq)*exp(-g*tc/C);
valid=vc>=p.warning_V;
vShown=vc; vShown(~valid)=NaN;
coilShown=g*vc; coilShown(~valid)=NaN;
fig2=figure('Name','Ideal capacitor support - not chip transient','Color','w');
subplot(2,1,1);
plot(tc*1000,vShown,'b','LineWidth',1.4); hold on;
yline(p.warning_V,'r--','Illustrative minimum');
xline(crossTime*1000,'k--','Support ends'); grid on; ylabel('Voltage (V)');
title(sprintf('Coil only; ideal %.0f uF, ideal 1.5 A source, zero ESR',C*1e6));
subplot(2,1,2);
plot(tc*1000,coilShown,'m','LineWidth',1.2); hold on;
yline(p.reference_output_A,'k--','Ideal assumed converter contribution');
ylabel('Current (A)'); xlabel('Time after energizing (ms)'); grid on;
legend('Coil current while >= warning voltage','Location','best');

%% 5. SAVE
if p.save_outputs
 writetable(summary,fullfile(outDir,'LTC3111_Load_screen.csv'));
 writetable(inputScreen,fullfile(outDir,'LTC3111_Input_voltage_screen.csv'));
 writetable(capSupport,fullfile(outDir,'Ideal_capacitor_support.csv'));
 safeSave(fig1,fullfile(outDir,'LTC3111_Load_comparison.png'));
 safeSave(fig2,fullfile(outDir,'Ideal_capacitor_support.png'));
 save(fullfile(outDir,'LTC3111_results.mat'),'p','t','demand','summary',...
  'inputScreen','capSupport','requiredIdealC','requiredConstantC');
 fprintf('Saved to: %s\n',outDir);
end
fprintf(['CONCLUSION: LTC3111 is not supported as the direct 5 V/4 A coil supply\n'...
 'by its continuous-output specification. Sequencing removes LTE overlap,\n'...
 'but the coil alone still exceeds that specification. Hardware validation\n'...
 'and a suitable higher-current power stage are needed for this load.\n']);

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
function safeSave(h,path)
if ~isgraphics(h,'figure'), return; end
try, exportgraphics(h,path,'Resolution',180);
catch
 try, print(h,path,'-dpng','-r180');
 catch err, warning('Figure export skipped: %s',err.message); end
end
end

