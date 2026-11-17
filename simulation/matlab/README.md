# **MATLAB Simulations**
# Simulation: Solenoid with Test Cases 
## Assumptions
- Solenoid: 5 V, 4 A
- Power-bank output limit: assumed 3.5 A
- Capacity comparison: 10,000–15,000 mAh
<img width="1297" height="596" alt="image" src="https://github.com/user-attachments/assets/dd0c9b7b-6186-4dab-bb6d-68a777a6aa43" />
<img width="1267" height="661" alt="image" src="https://github.com/user-attachments/assets/5b46325b-7e7c-4351-9374-56e82758dce1" />
<img width="957" height="505" alt="image" src="https://github.com/user-attachments/assets/6f0b995d-25d1-4a6c-b1d6-d34ed098a67c" />
<img width="997" height="487" alt="image" src="https://github.com/user-attachments/assets/5a805312-5bc2-4906-8f7b-94d361d73f8e" />
<img width="1220" height="612" alt="image" src="https://github.com/user-attachments/assets/c037380b-1103-4364-89db-8b6a78779e37" />
<img width="1487" height="696" alt="image" src="https://github.com/user-attachments/assets/84a91d2f-ce95-4e27-86bb-e1380f096a6f" />
<img width="1362" height="582" alt="image" src="https://github.com/user-attachments/assets/0a121582-def0-44ac-aa9f-516956338066" />
<img width="1372" height="817" alt="image" src="https://github.com/user-attachments/assets/65722e4a-e98d-41ff-b018-2d4ad25cbd0f" />
<img width="1467" height="772" alt="image" src="https://github.com/user-attachments/assets/a659e8b5-27a0-4004-8be5-3c5ae67cf737" />
<img width="1586" height="740" alt="image" src="https://github.com/user-attachments/assets/dc0a04c1-ecc6-4122-8766-571354288005" />

# Simulation: LTC3111 check for fall-vest 5 V / 4 A solenoid
##  Assumptions
- Solenoid: 5 V, 4 A, as specified by the team.
- Solenoid activation duration: 0.5 seconds.
- ESP32 and sensor current: 55 mA combined.
- LTE transmission current: 2 A stress-test assumption.
- Converter efficiency: assumed 90% for input-current calculations.
- Capacitor-support calculation assumes zero ESR (Equivalent Series Resistance) and an ideal 1.5 A source.
<img width="1315" height="716" alt="image" src="https://github.com/user-attachments/assets/2e4229bf-f2ff-4eb1-8c23-d423b912600d" />
Figure 1:
Blue — solenoid only: Draws a requested 4 A from about 2–2.5 seconds.
Orange — everything simultaneously: Solenoid and LTE activate together, raising demand to approximately 6.12 A. After the solenoid switches off, LTE keeps demand near 2.1 A until 3 seconds.
Yellow — solenoid, then LTE: Separating activation reduces the peak to approximately 4.14 A. LTE then transmits after the solenoid pulse finishes.
The red dashed line is 7.5 W, corresponding to 5 V x 1.5 A. Bars above it require more power.
<img width="1401" height="687" alt="image" src="https://github.com/user-attachments/assets/8030b491-888e-466b-aabd-91b7a8e2e878" />
Figure 2:
The capacitor is there to briefly supply extra current when the solenoid turns on, helping prevent the supply voltage from dropping.
4.75 V, our assumed minimum acceptable voltage. When the curve falls below it, capacitor support has ended for that assumption.


