/*
 * Copyright (c) 2010, KTH Royal Institute of Technology
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 *  - Redistributions of source code must retain the above copyright notice, this list
 * 	  of conditions and the following disclaimer.
 *
 * 	- Redistributions in binary form must reproduce the above copyright notice, this
 *    list of conditions and the following disclaimer in the documentation and/or other
 *	  materials provided with the distribution.
 *
 * 	- Neither the name of the KTH Royal Institute of Technology nor the names of its
 *    contributors may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
 * OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 */
/**
 * @author David Andreu <daval@kth.se>
 * @author Jose Araujo <araujo@kth.se>
 * Modified by Behdad Aminian <behdad@kth.se>
 * @version  $Revision: 1.0 Date: 2011/12/3 $ 
 */



#include "app_parameters.h"
#include "app_wt_calibration.h"
#include <printf.h>

module ControllerC {
	uses {

	/*********************************************************************
		* 1) Interfaces definition
	*********************************************************************/

		interface Boot;
		interface Leds;

		interface Timer<TMilli> as TimerPhase;
		interface Timer<TMilli> as Timertxbeacon;
		interface Timer<TMilli> as Timercheckhealth;
		interface Timer<TMilli> as Timertxdist;
		interface Receive;
		interface Packet;
		interface AMPacket;
		interface AMSend;
		interface SplitControl as AMControl;
		
		interface GeneralIO as ADC0;
		interface GeneralIO as ADC1;
		
		interface Random;

	}
}
implementation {


#define maxv 20
//#define PRINTFENABLED 1

	/*********************************************************************
		* 2) Variable definition
	*********************************************************************/
	
	uint16_t u;	// control input
	uint16_t u0;	// control input in the end of 1st phase
	
	uint16_t kp;	// proportional gain
	uint16_t ki;	// integral gain	
	uint16_t kd;	// derivative gain

	uint16_t pc;	// proportional part of u
	uint16_t ic;	// integral part of u	
	uint16_t dc;	// derivative part of u
	
	nx_float x_ref;
	nx_float op_point;	// operating point for 1st phase
	nx_float outf0;	// auxiliary variable
	uint16_t e;	// output error

	
	uint16_t beta; //  1v in the pump is approx. 273 units in the DAC
	
	// Other variables
	bool busy;
	bool transmitted;
	message_t pktToActuator;
	message_t pktToRelayNode;
	message_t pktBroadcast;

	nx_float x_int;
	
	nx_float K[3];
	uint16_t i_p;

	uint8_t m_state;
	uint8_t srcid;

	uint8_t flagphase;
	bool relay;
	bool start;

	uint32_t period;

	uint8_t ngbrnum0[maxv];
	uint8_t ngbrnn0[maxv];
	nx_float ngbrvalmu0[maxv];
	nx_float ngbrvaleta0[maxv];
	nx_float ngbrvaleta1[maxv];
			
	uint8_t ngbrnumrx[maxv];
	uint8_t ngbrnnrx[maxv];
	nx_float ngbrvalmurx[maxv];
	nx_float ngbrvaleta0rx[maxv];
	nx_float ngbrvaleta1rx[maxv];
	
	uint8_t faultnode[maxv];
		
	nx_float mmatchval;
	
	uint8_t ngbrct0;
	uint8_t ngbrct;

	uint8_t numpktC;
	uint16_t numpktCcount;
	uint16_t logpktC;
	uint16_t tmp;
	
	uint8_t counterrx;
	
	uint8_t trigger;
	uint8_t resetvar;
	uint8_t triggertosend;
	// stuff for dist algorithm
	
	nx_float I[2][2];
	nx_float M[4];
	nx_float delta;
	nx_float eta[2][1];
	nx_float alpha[8];
	
	/*********************************************************************
		* 3) Booting functions and Variable value assignment
	*********************************************************************/

void matrix_multiply(uint8_t m, uint8_t p, uint8_t n, nx_float matrix1[m][p], nx_float matrix2[p][n], nx_float output[m][n]);
void matrix_multiply_scalar(uint8_t m, uint8_t n, nx_float scalar, nx_float matrix2[m][n], nx_float output[m][n]);
void matrix_add(uint8_t m, uint8_t n, nx_float matrix1[m][n], nx_float matrix2[m][n], nx_float output[m][n]);
void matrix_sub(uint8_t m, uint8_t n, nx_float matrix1[m][n], nx_float matrix2[m][n], nx_float output[m][n]);
void printfFloat(nx_float toBePrinted); // For printing out float numbers
void matrix_print( uint8_t m, uint8_t n, nx_float matrix[m][n]);

	event void Boot.booted() {
		
		uint8_t i;
		uint8_t ptrv;
				

		u = 0;
		x_int = 700;
		
		busy = FALSE;
		transmitted = FALSE;
		
		
		
		ngbrct0 = 0;
		ngbrct = 0;
		numpktC = 0;
		    
		//initialize the stats
		for(i=0;i<maxv;i++){
      			ngbrnum0[i] = 0;
			ngbrnn0[i] = 0;
			ngbrvalmu0[i] = 0;
			ngbrvaleta0[i] = 0;
			ngbrvaleta1[i] = 0;
			faultnode[i] = 0; 
    		}
    
//					
		atomic {
			ADC12CTL0 = REF2_5V +REFON;
			DAC12_0CTL = DAC12IR + DAC12AMP_5 + DAC12ENC;
		}
//		
		//To not disturb the Sensor Values
		call ADC0.makeInput();
		call ADC1.makeInput();
		DAC12_0DAT = 0;


		flagphase = 1;
		call AMControl.start(); // We need to start the radio
		
		counterrx = 0;
		
		// distributed algorithm
		
		I[0][0] = 1.0000;
		I[0][1] = 0.0000;
		I[1][0] = 0.0000;
		I[1][1] = 1.0000;

		M[0] = 1.0000;
		M[1] = 0.6000;
		M[2] = 0.7000;
		M[3] = 1.1000;
		
		
		alpha[0] = 0.5903;
		alpha[1] = -0.0181;
		alpha[2] = 0.3542;
		alpha[3] = -0.0108;
		alpha[4] = 0.4132;
		alpha[5] = -0.0127;
		alpha[6] = 0.6494;
		alpha[7] = -0.0199;
		
		ptrv = TOS_NODE_ID - 2;
		eta[0][0] = alpha[2*ptrv];
		eta[1][0] = alpha[2*ptrv + 1];

		delta = -0.05;
		
		call TimerPhase.startPeriodic(SAMPLING_PERIOD+50);
		numpktCcount = 1;	
		tmp = 1;
		
		resetvar = 0;
		triggertosend = 0;
	}


	/********************************************************************
		* Message reception 
	*********************************************************************/

	event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {

		uint8_t i, kk;
		nx_float x1;	// upper tank	
		nx_float x2; 	// lower tank
		nx_float x1t; 	// lower tank
		nx_float x2t; 	// lower tank
		nx_float outf;	// auxiliary variable
		uint16_t outi;
		
		// If it is a msg from the controller with the sensor values
		srcid = call AMPacket.source(msg);
		#ifdef PRINTFENABLED
			printf("P: srcid %d\n",srcid);		
		#endif
		if ((len == sizeof(xpkt)) && (srcid == 1)) {
			
			numpktC = numpktC + 1;
		//printf("P: srcid %d\n",srcid);			
			call Leds.led2Toggle();  //toggle led 2 whenever receiving a message
			atomic {
				xpkt* svpkt = (xpkt*)payload;
					
				call Timertxbeacon.startOneShot(TOS_NODE_ID*75);
				
				if (numpktC > 4){
					call Timercheckhealth.startOneShot(512);
				}
						
				// Store sensor values
				x1t = (svpkt->xval1);
				x2t = (svpkt->xval2);
				x1 = (nx_float) x1t/100;
				x2 = (nx_float) x2t;
				
				x_int += (nx_float) (x2 - x1);
				#ifdef PRINTFENABLED
					printf("P: print xs\n");
					printfFloat(x1);
					printfFloat(x2);	
					printf("P: print  my eta\n");
					printfFloat(eta[0][0]);
					printfFloat(eta[1][0]);	
				#endif							
				outf = - (x1 * eta[0][0] + x_int * eta[1][0]);
				#ifdef PRINTFENABLED
					printfFloat(outf);
				#endif
				outf = outf*100 + 2000;
				#ifdef PRINTFENABLED
					printf("P: received [%ld,%ld], outf %d\n", (svpkt->xval1), (svpkt->xval2), (uint16_t)  outf);
				#endif
				
				if(outf < 0) outf = 0;
				else if(outf > 4095) outf = 4095;

				u = (uint16_t) outf;
	
				DAC12_0DAT = u;	

				// to anounce that he is alive 
				//call Timertxbeacon.startOneShot(call Random.rand16() % 50);
				
				// clean the vars with the details of what has been received
				ngbrct = counterrx;	
				counterrx = 0;
				for(i=0;i<maxv;i++){
					ngbrnumrx[i] = 0;
					ngbrnnrx[i] = 0;
					ngbrvalmurx[i] = 0;
					ngbrvaleta0rx[i] = 0;
					ngbrvaleta1rx[i] = 0;
    				}	
    				
    				if (resetvar == 1){
    					
					ngbrct0 = 0;
					for(kk=0;kk<maxv;kk++){
			      			ngbrnum0[kk] = 0;
						ngbrnn0[kk] = 0;
						ngbrvalmu0[kk] = 0;
						ngbrvaleta0[kk] = 0;
						ngbrvaleta1[kk] = 0;
						faultnode[kk] = 0; 
			    		}
			    	}		
			}
		}	
		
		// receiving the beacon with stats	
		if ((len == sizeof(beaconpkt)) && (srcid != 1) ) {		
			beaconpkt* apkt = (beaconpkt*)payload;
			
			uint8_t ngbrnumtmp;
			uint8_t ngbrnntmp;
			nx_float ngbrvalmutmp;
			nx_float ngbrvaleta0tmp;
			nx_float ngbrvaleta1tmp;

				
			ngbrnumtmp = srcid;
			ngbrnntmp = (apkt->beacon_nn);
			ngbrvalmutmp = (nx_float) (apkt->beacon_mu)/1000;
			
			ngbrvaleta0tmp = (nx_float) (apkt->beacon_eta0)/1000;
			ngbrvaleta1tmp = (nx_float) (apkt->beacon_eta1)/1000;
			#ifdef PRINTFENABLED
				printf("P: print eta received from neighbor %d\n", srcid);
				printfFloat(ngbrvaleta0tmp);
				printfFloat(ngbrvaleta1tmp);
				printf("P: print mu received from neighbor %d\n", srcid);
				printfFloat(ngbrvalmutmp);
			#endif
			// only allow trigger to change if it was to run the dist. Otherwise each node should be the one deciding when to stop!
			if (trigger == 0){ 
				trigger = (apkt->beacon_trigger);
			}
			
			//srcid = call AMPacket.source(msg);
			//printf("P: got a packet from neighbor %d\n",srcid);
			
			if (numpktC == 4 || resetvar == 1){ // just enter here for the first time it runs
				ngbrnum0[ngbrct0] = ngbrnumtmp;
				ngbrnn0[ngbrct0] = ngbrnntmp;
				ngbrvalmu0[ngbrct0] = ngbrvalmutmp;
				ngbrvaleta0[ngbrct0] = ngbrvaleta0tmp;
				ngbrvaleta1[ngbrct0] = ngbrvaleta1tmp;
				#ifdef PRINTFENABLED
					printf("P0: print eta received from neighbor %d, nn0= %d\n", ngbrnum0[ngbrct0], ngbrnn0[ngbrct0] );
					printfFloat(ngbrvaleta0[ngbrct0]);
					printfFloat(ngbrvaleta1[ngbrct0]);
					printf("P0: print mu received from neighbor %d\n", srcid);
					printfFloat(ngbrvalmu0[ngbrct0]);	
				#endif			
				ngbrct0 = ngbrct0 + 1;
				#ifdef PRINTFENABLED
				printf("P: init vars0\n");
				#endif
			
			}
			
				ngbrnumrx[counterrx] = ngbrnumtmp;
				ngbrnnrx[counterrx] = ngbrnntmp;
				ngbrvalmurx[counterrx] = ngbrvalmutmp;
				ngbrvaleta0rx[counterrx] = ngbrvaleta0tmp;
				ngbrvaleta1rx[counterrx] = ngbrvaleta1tmp;
				counterrx = counterrx + 1;

			
				
				call Leds.led0Toggle();  //toggle led 0 whenever receiving a message of this type
				
		}	
		
		
			
		return msg;
	}


	event void TimerPhase.fired() {
		if (numpktCcount - tmp == 2){ // check only every 2nd packet
			tmp = numpktCcount;
			if (logpktC == numpktC){
			#ifdef PRINTFENABLED
				printf("P: not receiving message from the controller\n");
			#endif	
				atomic{
				DAC12_0DAT = 1000;
				}
			}else{
			#ifdef PRINTFENABLED
				printf("P: receiving message from the controller\n");
			#endif
				logpktC = numpktC;
				
			}
		}
	
		numpktCcount = numpktCcount + 1;
	}	
	
	/********************************************************************
		* Send the beacon message after the reception of the sensor data
	*********************************************************************/
	
	event void Timertxbeacon.fired() {
		
		int32_t eta0tmp;
		int32_t eta1tmp;
		
		beaconpkt* apkt = (beaconpkt*)(call Packet.getPayload(&pktToActuator, sizeof (beaconpkt)));
		
		
		apkt->beacon_trigger = triggertosend; // warn the neighbors that there was a fault!
		apkt->beacon_nn = ngbrct; // number of neighbors we have
		apkt->beacon_mu = M[TOS_NODE_ID-2]*1000;
		
		if (triggertosend == 1){ // reset this value as this is just a trigger to be sent once!
			triggertosend = 0;
		}
		//printf("P: print eta before sending \n");
		//printfFloat(eta[0][0]);
		//printfFloat(eta[1][0]);
		
		eta0tmp = eta[0][0]*1000;
		eta1tmp = eta[1][0]*1000;
		
		//printf("P: print eta sent [%ld, %ld] \n",eta0tmp,eta1tmp);
		
		apkt->beacon_eta0 = eta0tmp;
		apkt->beacon_eta1 = eta1tmp;
		
		//printf("P: my mu is \n");
		//printfFloat(M[TOS_NODE_ID-2]);		
		
		if (!busy) {
		 	if (call AMSend.send(AM_BROADCAST_ADDR, &pktToActuator, sizeof(beaconpkt)) == SUCCESS) {
				busy = TRUE;}
		}
		#ifdef PRINTFENABLED
		printf("P: I currently have %d neighbors and trigger= %d\n",ngbrct,trigger);
		#endif
		
		
	}
	
	/********************************************************************
		* Timer to check the health and run the distributed algorithm in case a fault has occurred
	*********************************************************************/
	
	event void Timercheckhealth.fired() {
		uint8_t i, j, n, k;
		uint8_t nfaults;
		uint8_t flaghealth;
		
		nx_float resa[2][1];
		nx_float resb[2][1];
		nx_float etarx[2][1];
		nx_float etanew[2][1];
		nx_float etaW[2][1];
		nx_float cte;
		nx_float v;
		nx_float v1;
		nx_float v2;
		nx_float v3;
		nx_float v4;
		nx_float v5;
		nx_float diff1;
		nx_float diff2;
		
		nfaults = 0;
		
		#ifdef PRINTFENABLED
			printf("P: timer fired to check health \n");		
			printf("P: print eta k\n");
			printfFloat(eta[0][0]);
			printfFloat(eta[1][0]);
		#endif
		/*********************************************************************
	 	* RUN THE DISTRIBUTED RECONFIGURATION . run it before the detection so it doesnt run after the fault but waits for the next step
	 	**********************************************************************/
	 	resetvar = 0; // reset the resetvar
		if (trigger == 1){ // if we have to run the algorithm!
	    		    	printf("P: FAULT: fault occurred and will run reconfiguration\n");
	    		    	
	    		    	etaW[0][0] = 0;
				etaW[1][0] = 0;				
				// calculate the new eta with boyd W
				for (k=0;k<counterrx;k++){
					flaghealth = 1;
					for (n=0;n<maxv;n++){ 
					// searches all nodes in the faultnode list
					// this is just to avoid any problems!
						if (ngbrnumrx[k] == faultnode[n]){ 
							// this node is in the fault list, dont do anything
							#ifdef PRINTFENABLED
								printf("P: FAULT:this node is in the fault list, dont do anything\n");
							#endif
							flaghealth = 0;
							break;
						}
					}
					if (flaghealth == 1){
						// check if this node was not faulty!
						#ifdef PRINTFENABLED
							printf("P: FAULT: Calculating eta with info from neighbors, step %d\n",k);	
						#endif			
						cte = -2*(delta/M[TOS_NODE_ID-2])*(-1/ngbrvalmurx[k]);
						#ifdef PRINTFENABLED
							printf("P: print cte for ngbr %d\n",ngbrnumrx[k]);
							printfFloat(cte);
							printf("P: print mu ngbr\n");
							printfFloat(ngbrvalmurx[k]);
						#endif
						etarx[0][0] = ngbrvaleta0rx[k];
						etarx[1][0] = ngbrvaleta1rx[k];
						//matrix_multiply(2,2,1,I,etarx,resa);
						#ifdef PRINTFENABLED
							printf("P: print etarx\n");
							printfFloat(etarx[0][0]);
							printfFloat(etarx[1][0]);
						#endif
						resb[0][0] = cte*etarx[0][0];	
						resb[1][0] = cte*etarx[1][0];	
						#ifdef PRINTFENABLED
							printf("P: print resb\n");
							printfFloat(resb[0][0]);
							printfFloat(resb[1][0]);
						#endif				
						//matrix_multiply(2,1,1,resa,cte,resb);
						matrix_add(2,1,etaW,resb,etaW);				
					}
						
				}
				#ifdef PRINTFENABLED
					printf("P: print etaW\n");
					printfFloat(etaW[0][0]);
					printfFloat(etaW[1][0]);				
					printf("P: FAULT: Calculating eta adding own contrib\n");	
				#endif		
				cte = -2*(delta/M[TOS_NODE_ID-2])*(counterrx/M[TOS_NODE_ID-2]);
				#ifdef PRINTFENABLED
					printf("P: print cte\n");
					printfFloat(cte);
				#endif
				//matrix_multiply(2,2,1,I,eta,resa);
				//printf("P: print resa\n");
				///printfFloat(resa[1][0]);
				//matrix_multiply(2,1,1,resa,cte,resb);
				resb[0][0] = cte*eta[0][0];	
			 	resb[1][0] = cte*eta[1][0];
			 	#ifdef PRINTFENABLED
				 	printf("P: print resb\n");
					printfFloat(resb[0][0]);
					printfFloat(resb[1][0]);
				#endif
				matrix_add(2,1,etaW,resb,etanew); // result ends up with eta
				#ifdef PRINTFENABLED
					printf("P: print etanew\n");
					printfFloat(eta[0][0]);
					printfFloat(eta[1][0]);
				#endif
				matrix_sub(2,1,eta,etanew,resa); //result ends up with eta
				
				#ifdef PRINTFENABLED
					printf("P: print eta k+1\n");
				#endif
							
				diff1 = 10000*(resa[0][0] - eta[0][0]);
				if (diff1 < 0){
					diff1 = -diff1;
				}
				diff2 = 10000*(resa[1][0] - eta[1][0])*(resa[1][0] - eta[1][0]);
				if (diff2 < 0){
					diff2 = -diff2;
				}					
				if (diff1 < 1 && diff2 < 1){
					trigger = 0;
					resetvar = 1;
					
    		
					printf("P: stopping the algorithm since we converged!\n");				
				}
				eta[0][0] = resa[0][0];
				eta[1][0] = resa[1][0];
				printfFloat(eta[0][0]);
				printfFloat(eta[1][0]);
				
				
		}
	
		/*********************************************************************
	 	* CHECK IF SOME NODE FAILED
	 	**********************************************************************/
	 	
			
		if (counterrx == ngbrct0){
			#ifdef PRINTFENABLED
				printf("P: no fault: initial neighbors = %d, current number = %d\n",ngbrct0, counterrx );
			#endif
		}
		else{
			printf("P: FAULT: initial neighbors = %d, current number = %d\n",ngbrct0, counterrx);
			for(i=0;i<ngbrct0;i++){
				flaghealth = 0;
				#ifdef PRINTFENABLED
				printf("P: FAULT: checking which neighbor failed i= %d\n",i);
				#endif
					for(j=0;j<counterrx;j++){
						if (ngbrnum0[i] == ngbrnumrx[j]){ // we received beacon from this guy so we dont do anything	
							#ifdef PRINTFENABLED
								printf("P: FAULT: neighbor %d is still healthy\n",ngbrnumrx[j]);
							#endif
							flaghealth = 1; 
							break;
						}
					}
				
					if (flaghealth == 0){ // this means that the node i has gone faulty
						#ifdef PRINTFENABLED
							printf("P: FAULT: node %d got a fault\n",ngbrnum0[i]);
						#endif				
						// log the id of the failed node to keep in memory
						for (n=0;n<maxv;n++){ // remove this node from the failed node list if it has failed before
							if (faultnode[n] == 0){
								#ifdef PRINTFENABLED
									printf("P: FAULT: place node %d in the fault log \n",ngbrnum0[i]);
								#endif
								faultnode[n] = ngbrnum0[i]; 
								break;
							}
						}
					
						// calculate eta(0) since the node failed!
						#ifdef PRINTFENABLED
							printf("P: FAULT: calculate new eta0 because node %d failed\n",ngbrnum0[i]);
						#endif
						etarx[0][0] = ngbrvaleta0[i];
						etarx[1][0] = ngbrvaleta1[i];
						#ifdef PRINTFENABLED
							printf("P: print etarx\n");
							printfFloat(etarx[0][0]);
							printfFloat(etarx[1][0]);
						#endif
						v1 = (nx_float) 1/ngbrnn0[i];
						#ifdef PRINTFENABLED
							printf("P: print nnbr0, %d\n",ngbrnn0[i]);
							//printf("P: v1 value is\n");
							//printfFloat(v1);
							printf("P: mu0 value is\n");
							printfFloat(ngbrvalmu0[i]);
						#endif
						v = v1*ngbrvalmu0[i]/M[TOS_NODE_ID-2];
						#ifdef PRINTFENABLED
							printf("P: v value is\n");
							printfFloat(v);
						#endif
						//etarx = v*etarx;
						//matrix_multiply(2,1,1,etarx,v,etarx);
						v3 = v*etarx[0][0];
						v4 = v*etarx[1][0]; 
						
						etarx[0][0] = v3;
						etarx[1][0] = v4;
						//etarx[0][0] = v[0][0]*etarx[0][0];
						//etarx[1][0] = v[0][0]*etarx[1][0];
						#ifdef PRINTFENABLED
							printf("P: print etarx after\n");
							printfFloat(etarx[0][0]);
							printfFloat(etarx[1][0]);
						#endif
						matrix_add(2,1,eta,etarx,etanew); 
						#ifdef PRINTFENABLED
							printf("P: print eta0 after fault\n");
						#endif
						printfFloat(etanew[0][0]);
						printfFloat(etanew[1][0]);
						eta[0][0] = etanew[0][0];
						eta[1][0] = etanew[1][0];
						trigger = 1;
						triggertosend = 1;
						nfaults = nfaults + 1;	
										
					}
	    		}
	    		ngbrct0 = counterrx;
	    	} 
	    	// log the number of neighbors so it can be used next time! 
    		// update with the faults!
	    	//ngbrct = ngbrct0 - nfaults;
	    	
	    	ngbrct = counterrx;
	    	
				
	}
	event void Timertxdist.fired() {
		uint8_t i;
		i = 0;
	}

	/*********************************************************************
	 	* 9) Message functions
	 **********************************************************************/

	event void AMControl.startDone(error_t err) {
		if (err == SUCCESS) {

		}
		else {
			call AMControl.start();
		}
	}

	event void AMControl.stopDone(error_t err) {
	}

	event void AMSend.sendDone(message_t* msg, error_t error) {
		if ((&pktToActuator == msg)) {
			call Leds.led1Toggle();
			busy = FALSE;
		}
	}

/*********************************************************************
	 	* Matrix stuff
	 **********************************************************************/
	

void matrix_multiply(uint8_t m, uint8_t p, uint8_t n, nx_float matrix1[m][p], nx_float matrix2[p][n], nx_float output[m][n])
{
    uint8_t i, j, k;
    for (i = 0; i < m; i++)
        for (j = 0; j < n; j++)
            output[i][j] = 0.0;
        	
    for (i = 0; i < m; i++)
        for (j = 0; j < p; j++)
            for (k = 0; k < n; k++){
                output[i][k] += matrix1[i][j] * matrix2[j][k];
                }
}

void matrix_sub(uint8_t m, uint8_t n, nx_float matrix1[m][n], nx_float matrix2[m][n], nx_float output[m][n])
{
    uint8_t i,j;
    for(i = 0; i < m ; i++)
    	for(j = 0; j < n; j++)
    		output[i][j] =  (matrix1[i][j] - matrix2[i][j]);
}  


void matrix_multiply_scalar(uint8_t m, uint8_t n, nx_float scalar, nx_float matrix2[m][n], nx_float output[m][n])
{
    uint8_t i, j; 
    for (i = 0; i < m; i++)
        for (j = 0; j < n; j++)
            output[i][j] = 0.0;
            
    for (i = 0; i < m; i++){
        for (j = 0; j < n; j++){
            output[i][j] += scalar*matrix2[i][j];}}
        	

}

void matrix_add(uint8_t m, uint8_t n, nx_float matrix1[m][n], nx_float matrix2[m][n], nx_float output[m][n])
{
    uint8_t i,j;
    for(i = 0; i < m ; i++)
    	for(j = 0; j < n; j++)
    		output[i][j] =  (matrix1[i][j] + matrix2[i][j]);
}  	
	
	
	void matrix_print( uint8_t m, uint8_t n, nx_float matrix[m][n])
{
	uint8_t i, j;
	for (i = 0; i < m; i++)
        	for (j = 0; j < n; j++)
        		printfFloat(matrix[i][j]);

}
  
  void printfFloat(nx_float toBePrinted) {
		uint32_t fi, f0, f1, f2;
		char c;
		nx_float f;
		
		f = toBePrinted;

		if (f<0) {
			c = '-'; f = -f;
		} else {
			c = ' ';
		}

		// integer portion.
		fi = (uint32_t) f;

		// decimal portion...get index for up to 3 decimal places.
		f = f - ((nx_float) fi);
		f0 = f*10; f0 %= 10;
		f1 = f*100; f1 %= 10;
		f2 = f*1000; f2 %= 10;
		printf("P: %c%ld.%d%d%d \n", c, fi, (uint8_t) f0, (uint8_t) f1,
				(uint8_t) f2);
				
		
	}
	
	/*********************************************************************
	 	* END *
	 **********************************************************************/

}
