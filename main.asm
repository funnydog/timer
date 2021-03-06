        include "config.inc"
        include "delay.inc"
        include "i2c.inc"
        include "macro.inc"

        ;; fuses configuration
        config  FOSC=INTOSCIO, CFGPLLEN=OFF, CPUDIV=NOCLKDIV
        config  PWRTEN=ON, BOREN=NOSLP, BORV=285, LPBOR=OFF
        config  WDTEN=OFF
        config  MCLRE=ON, PBADEN=OFF
        config  DEBUG=OFF, XINST=OFF, LVP=OFF, STVREN=OFF
        config  CP0=OFF, CP1=OFF, CP2=OFF, CP3=OFF, CPB=OFF, CPD=OFF
        config  WRT0=OFF, WRT1=OFF, WRT2=OFF, WRT3=OFF, WRTB=OFF, WRTD=OFF
        config  EBTR0=OFF, EBTR1=OFF, EBTR2=OFF, EBTR3=OFF, EBTRB=OFF

        ;; constants
B       equ     BANKED
TIMEOUT equ     60              ; default timeout
TDELAY  equ     250             ; initial key repeat delay in ticks (1sec)
TREPEAT equ     25              ; next key repeat delay in ticks (0.1sec)
MAXSLOT equ     10              ; max number of presets
SLOTDLY equ     2               ; duration of slot display view
TOTBZCN equ     4               ; number of buzz cycles (on + off)
BEEPSEC equ     1               ; duration of a beep in seconds

        ;; timer events flags
LIGHTON equ     0               ; light on event
BUZZSIG equ     1               ; buzz signal event
SHOWSLT equ     2               ; show preset event

        ;; other flags
BUZZCHG equ     3               ; the acoustic/visual signal needs to change
REFRESH equ     4               ; the display needs refresh
LEADING equ     5               ; don't print the leading zero
REPEAT  equ     6               ; key repeat fired

        ;; buttons
BSTART  equ     0               ; start the countdown
BPLUS   equ     1               ; increase the timeout
BMINUS  equ     2               ; decrease the timeout
BTOGGLE equ     3               ; toggle full/1st half/2nd half rows
BSLOT   equ     4               ; increase the slot number
KBLED   equ     5               ; keyboard led (output)

.data   udata

        ;; variables
runout  res     2               ; timeout in seconds running value
timeout res     2               ; timeout in seconds stored value
rmask   res     1               ; relay bitmask
bstate  res     10              ; 10 debounces of 4ms each
bindex  res     1               ; current index into bstate[]
button  res     2               ; button status [0 = current, 1 = old ]
dbuf    res     9               ; display buffer
tmp     res     2               ; temporary values
flags   res     1               ; flags
tsec    res     1               ; tick counter, 250 ticks == 1s
tdel    res     1               ; repeat delay counter
slot    res     1               ; current slot number
buzcnt  res     1               ; buzz cycles left

.edata  code    0xF00000

        ;; variables stored in EEPROM: timeoutL, timeoutH, rmask
        ;; 10 slots of presets initialized to default values
saved   de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3
        de      LOW(TIMEOUT), HIGH(TIMEOUT), 3

        ;; entry code section
.reset  code    0x0000
        bra     start

.isr    code    0x0008
        bra     isr

        ;; main code
.main  code
isr:
        ;; handler for the CCP2IF interrupt
        btfss   PIR2, CCP2IF, A
        bra     isr0_end
        bcf     PIR2, CCP2IF, A

        ;; save the current state of the buttons
        movlb   0x0
        lfsr    FSR2, bstate
        movf    bindex, W, B
        addwf   FSR2L, F, A
        skpnc
        incf    FSR2H, F, A
        movf    PORTA, W, A
        andlw   0x3F
        movwf   INDF2, A

        ;; compute the new button index
        incf    bindex, F, B
        movlw   -10
        addwf   bindex, W, B
        skpnc
        clrf    bindex, B

        ;; decrease or replenish tdel
        decf    tdel, F, B
        bnz     isr0_trepeat_end
        movlw   TREPEAT
        movwf   tdel, B
        bsf     flags, REPEAT, B
isr0_trepeat_end:

        ;; do not count seconds if not needed
        movlw   1<<LIGHTON | 1<<SHOWSLT | 1<<BUZZSIG
        andwf   flags, W, B
        bz      isr0_end

        ;; 1 second == 250 ticks of 4ms each
        decfsz  tsec, F, B
        bra     isr0_end
        movlw   250
        movwf   tsec, B

        ;; check if timeout is zero
        movf    runout+0, W, B
        iorwf   runout+1, W, B
        bnz     isr0_dec_timeout

        ;; common for every handler
        bsf     flags, REFRESH, B

        ;; timeout handler for LIGHTON event
        btfss   flags, LIGHTON, B
        bra     isr0_light_end
        bcf     flags, LIGHTON, B
        movlw   ~3
        andwf   LATC, F, A      ; relays off
        movlw   TOTBZCN*2       ; initialize the BUZZSIG event
        movwf   buzcnt, B
        movlw   BEEPSEC-1       ; BEEPSEC-1 + 250ticks
        movwf   runout+0, B
        bsf     flags, BUZZSIG, B
        bsf     flags, BUZZCHG, B
        bra     isr0_end
isr0_light_end:

        ;; timeout handler for BUZZSIG event
        btfss   flags, BUZZSIG, B
        bra     isr0_buzzsig_end
        dcfsnz  buzcnt, F, B
        bcf     flags, BUZZSIG, B
        movlw   BEEPSEC-1       ; BEEPSEC-1 + 250ticks
        movwf   runout+0, B
        bsf     flags, BUZZCHG, B
        bra     isr0_end
isr0_buzzsig_end:

        ;; timeout handler for SHOWSLT event
        btfss   flags, SHOWSLT, B
        bra     isr0_showslt_end
        bcf     flags, SHOWSLT, B
        bra     isr0_end
isr0_showslt_end:

isr0_dec_timeout:
        ;; timeout is not zero
        ;; decrease the timeout
        movlw   0
        decf    runout+0, F, B
        subwfb  runout+1, F, B
        btfsc   flags, LIGHTON, B
        bsf     flags, REFRESH, B

isr0_end:
isr_end:
        retfie  FAST

        ;; main code
start:
        ;; initialize the ports as digital outputs with value 0
        movlb   0xF             ; select the bank 0xF
        clrf    ANSELA, B       ; ANSEL A/B/C are not in ACCESS BANK
        clrf    ANSELB, B
        clrf    ANSELC, B
        clrf    LATA, B         ; clear the PORTA latches
        movlw   0x1F
        movwf   TRISA, B        ; set RA0..RA4 as inputs, RA5 as output
        clrf    LATB, B         ; clear the PORTB latches
        clrf    TRISB, B        ; set RB0..RB7 as outputs
        clrf    LATC, B         ; clear the PORTC latches
        clrf    TRISC, B        ; set RC0..RC7 as outputs

        ;; speed up the internal clock to 16MHz
        bsf     OSCCON, IRCF2, B ; increase the freq to 16MHz
        delaycy 65536            ; a small delay for things to settle
        movlb   0x0              ; select the bank 0

        ;; load the settings in eeprom
        clrf    slot, B
        call    read_eeprom

        ;; initialize bstate
        lfsr    FSR0, bstate
        movlw   10
main_l0:
        clrf    POSTINC0, A
        addlw   -1
        bnz     main_l0

        ;; initialize variables to default values
        call    seg_clear
        clrf    flags, B
        clrf    bindex, B
        movlw   250
        movwf   tsec, B
        clrf    buzcnt, B

        ;; initialize the periodic TMR1
        ;; period = 16000 * 0.25 usec = 4msec
        movlb   0xF
        clrf    T1CON, B        ; no prescaler
        clrf    TMR1H, B
        clrf    TMR1L, B
        movlw   0x0B            ; configure CCP2 for special event
        movwf   CCP2CON, B
        bcf     CCPTMRS, C2TSEL, B ; not in ACCESS bank!!!
        movlw   HIGH(16000-1)
        movwf   CCPR2H, B
        movlw   LOW(16000-1)
        movwf   CCPR2L, B       ; set a period of 16000 * 0.25 usec

        ;; PWM for the acoustic signal
        ;; set TMR2 for a 1:16 prescaler and 103 ticks period
        ;; (i.e. 416us) that matches the resonant frequency
        ;; of the buzzer (2400 Hz)
        bsf     TRISB, 2, B
        movlw   103             ; 104 - 1
        movwf   PR2, B          ; (103+1) * 4 / 16Mhz * 16 = 416us
        movlw   0x06
        movwf   T2CON, B        ; 1:16 prescaler
        movlw   (208 & 3) << 4
        movwf   CCP1CON, B
        movlw   208 >> 2        ; (103+1) * 4 * 0.5 = 208
        movwf   CCPR1L, B
        movlw   1<<STR1SYNC|1<<STR1B
        movwf   PSTR1CON, B
        bcf     TRISB, 2, B

        ;; enable the interrupts
        bcf     PIR2, CCP2IF, B
        bsf     PIE2, CCP2IE, B
        bsf     INTCON, GIE, B
        bsf     INTCON, PEIE, B

        ;; enable TMR1
        bsf     T1CON, TMR1ON, B
        movlb   0x0

        ;; initialize I2C support
        call    i2c_init
        call    seg_init

        ;; write some numbers
        bcf     flags, LIGHTON, B
        bsf     flags, REFRESH, B
main_loop:
        call    task1           ; beep task
        call    task2           ; display task
        call    task3           ; input task
        bra     main_loop

        ;; task1 - signal the end of the countdown
        ;;
        ;; Signal the end of the countdown to the user
        ;; by means of:
        ;;   * 7seg display blinking
        ;;   * KBLED blinking
        ;;   * buzzer driven by PWM signal
task1:
        ;; buzz only when BUZZCHG
        btfss   flags, BUZZCHG, B
        return
        bcf     flags, BUZZCHG, B

        ;; check if this is the last BUZZCHG signal
        movf    buzcnt, F, B
        bnz     task1_alt_loop

        ;; PWM already OFF, display ON, KBLED already OFF
        movlw   0x81
        bra     seg_write

        ;; inside the alternate loop
task1_alt_loop:
        btfss   buzcnt, 0, B
        bra     task1_pwm_on

        ;; PWM OFF, display OFF, KBLED OFF for odd buzcnt
        bcf     LATA, KBLED, A
        movlw   0xF0
        andwf   CCP1CON, F, A
        movlw   0x80
        bra     seg_write

        ;; PWM ON, display ON, KBLED ON for even buzcnt
task1_pwm_on:
        bsf     LATA, KBLED, A
        movlw   0x0C
        iorwf   CCP1CON, F, A
        movlw   0x81
        bra     seg_write

        ;; task2 - 7seg display management
        ;;
        ;; Show the data on the 7seg display only when
        ;; the REFRESH flag is set:
        ;;   * BUZZSIG doesn't show anything
        ;;   * SHOWSLT shows the current preset slot
        ;;   * LIGHTON shows the runout value
        ;;   * or else show the timeout value
task2:
        ;; refresh only when REFRESH and !BUZZSIG
        btfss   flags, REFRESH, B
        return
        btfsc   flags, BUZZSIG, B
        return

        ;; show the current slot ("Pr %1d", slot)
task2_slot:
        btfss   flags, SHOWSLT, B
        bra     task2_time
        movlw   0x73            ; 'P'
        movwf   dbuf+0, B
        movlw   0x50            ; 'r'
        movwf   dbuf+2, B
        clrf    dbuf+6, B       ; ' '
        movf    slot, W, B
        bcf     flags, LEADING, B
        call    get_digit
        movwf   dbuf+8, B       ; [slot]
        bra     seg_send_buf

        ;; show timeout / runout ("%4d", lighton ? runout : timeout)
task2_time:
        ;; 16bit to BCD conversion
        ;; if LIGHTON --> show runout
        ;;    else    --> show timeout
        lfsr    FSR0, timeout
        btfss   flags, LIGHTON, B
        bra     task2_bcd
        lfsr    FSR0, runout
task2_bcd:
        call    b16_d5

        ;; convert the buffer to a proper
        ;; matrix representation taking into account
        ;; leading zeros
        bsf     flags, LEADING, B
        movf    dbuf+0, W, B    ; most significant digit
        call    get_digit
        btfsc   rmask, 1, B
        iorlw   0x80            ; dot on when (rmask & 2) != 0
        movwf   dbuf+0, B

        movf    dbuf+2, W, B
        call    get_digit
        btfsc   rmask, 1, B
        iorlw   0x80            ; dot on when (rmask & 2) != 0
        movwf   dbuf+2, B

        movf    dbuf+6, W, B
        call    get_digit
        btfsc   rmask, 0, B
        iorlw   0x80            ; dot on when (rmask & 1) != 0
        movwf   dbuf+6, B

        bcf     flags, LEADING, B
        movf    dbuf+8, W, B    ; least significant digit
        call    get_digit
        btfsc   rmask, 0, B
        iorlw   0x80            ; dot on when (rmask & 1) != 0
        movwf   dbuf+8, B

        bcf     flags, REFRESH, B
        bra     seg_send_buf

        ;; task3 - handle the keys
        ;;
        ;; Check the pushed keys:
        ;;   * BSTART  starts the countdown
        ;;   * BPLUS   increments the timeout
        ;;   * BMINUS  decreases the timeout
        ;;   * BTOGGLE toggles between the lamp modes
        ;;   * BSLOT   cycles through the presets
        ;;
        ;; The keys are debounced and checked for repetition.
task3:
        ;; read inputs if !LIGHTON and !BUZZSIG
        btfsc   flags, LIGHTON, B
        return
        btfsc   flags, BUZZSIG, B
        return

        ;; read the buttons, save the old read
        movf    button+0, W, B
        movwf   button+1, B
        call    get_switches

        ;; check the button START
        btfss   button+0, BSTART, B
        bra     task3_lighton_end

        ;; check if timeout is zero
        movf    timeout+0, W, B
        iorwf   timeout+1, W, B
        bz      task3_lighton_end

        ;; start the countdown
        call    update_eeprom
        movlw   250
        movwf   tsec, B         ; ensure tsec = 250
        decf    timeout+0, W, B
        movwf   runout+0, B
        movlw   0
        subwfb  timeout+1, W, B
        movwf   runout+1, B     ; runout = timeout - 1 + 250ticks
        bsf     LATA, KBLED, A  ; keyboard LED on
        movf    rmask, W, B
        iorwf   LATC, F, A      ; relays ON
        bsf     flags, REFRESH, B
        bsf     flags, LIGHTON, B
        return
task3_lighton_end:

        ;; check the button PLUS
        movlw   1 << BPLUS
        call    get_repeat
        bnc     task3_plus_end

        ;; check if the new value is < 9999
        movlw   LOW(0xFFFF - 9999 + 1)
        addwf   timeout+0, W, B
        movlw   HIGH(0xFFFF - 9999 + 1)
        addwfc  timeout+1, W, B
        bc      task3_plus_end

        ;; increase the seconds
        incf    timeout+0, F, B
        skpnc
        incf    timeout+1, F, B
        bsf     flags, REFRESH, B
task3_plus_end:

        ;; check the button MINUS
        movlw   1 << BMINUS
        call    get_repeat
        bnc     task3_minus_end

        ;; decrease the seconds
        movlw   0
        decf    timeout+0, F, B
        skpc
        decf    timeout+1, F, B
        bc      task3_minus_l0

        ;; but not below 0
        clrf    timeout+0, B
        clrf    timeout+1, B
task3_minus_l0:
        bsf     flags, REFRESH, B
task3_minus_end:

        ;; check the button TOGGLE
        movlw   1 << BTOGGLE
        call    get_repeat
        bnc     task3_toggle_end

        ;; increase rmask and rollover to 1
        ;; if greater than 3
        bsf     flags, REFRESH, B
        incf    rmask, F, B
        movf    rmask, W, B
        addlw   255 - 3
        addlw   (3 - 1) + 1
        bc      task3_toggle_end
        movlw   1
        movwf   rmask, B
task3_toggle_end:

        ;; check the button SLOT
        movlw   1 << BSLOT
        call    get_repeat
        bnc     task3_slot_end

        ;; increase slot and ensure its between 0 anx MAXSLOT-1
        incf    slot, F, B
        movf    slot, W, B
        addlw   255 - (MAXSLOT-1)
        addlw   (MAXSLOT-1 - 0) + 1
        skpc
        clrf    slot, B

        ;; update the timeout and rmask values from EEPROM
        ;; and show the slot number in the display for SLOTDLY
        ;; seconds
        call    read_eeprom
        clrf    runout+1, B
        movlw   250
        movwf   tsec, B
        movlw   SLOTDLY-1
        movwf   runout+0, B     ; SLOTDLY-1 + 250ticks
        bsf     flags, REFRESH, B
        bsf     flags, SHOWSLT, B
task3_slot_end:

        return

        ;; seg_init - initialize the 7seg display
        ;;
        ;; Initialize the 7seg display with the following settings:
        ;;  * duty cycle = 2/16
        ;;  * blink      = OFF
        ;;
        ;; Return: no value
seg_init:
        movlw   0x21            ; turn on system oscillator
        call    seg_write
        movlw   0xA3            ; set int/row output pins as high
        call    seg_write
        movlw   0xE1            ; set dimming duty cycle to 2/16
        call    seg_write
        movlw   0x81            ; turn on the display blink = OFF
        ;; proceed to seg_write

        ;; seg_write - write one byte to the display
        ;; @W: byte to write
        ;;
        ;; Write one byte to the display address (0xE0)
        ;;
        ;; Return: no value
seg_write:
        movwf   tmp, B
        call    i2c_start
        movlw   0xE0
        call    i2c_write
        skpnc
        bra     i2c_stop
        movf    tmp, W, B
        call    i2c_write
        bra     i2c_stop

        ;; seg_send_buf: copy dbuf[] into the 7seg display
        ;;
        ;; Copy the dbuf[9] array into the 7seg display
        ;; memory. The position of the digits are as follows:
        ;;  0 1 2 3 4 5 6 7 8 9
        ;;  -+-+-+-+-+-+-+-+-+-
        ;;  d   d   :   d   d
        ;;
        ;; Return: no value
seg_send_buf:
        call    i2c_start
        movlw   0xE0            ; 7seg display address
        call    i2c_write
        skpnc
        bra     i2c_stop        ; NACK
        movlw   0               ; address 0x00
        call    i2c_write
        skpnc
        bra     i2c_stop        ; NACK
        movlw   9
        movwf   tmp, B
        lfsr    FSR0, dbuf
seg_send_l0:
        movf    POSTINC0, W, A
        call    i2c_write
        skpnc
        bra     i2c_stop        ; NACK
        decf    tmp, F, B
        bnz     seg_send_l0
        bra     i2c_stop

        ;; seg_clear - clear the contents of dbuf[]
        ;;
        ;; Clear the contents of the dbuf[] array.
        ;;
        ;; Return: no value
seg_clear:
        movlw   9
        lfsr    FSR0, dbuf
seg_clear_l0:
        clrf    POSTINC0, A
        addlw   -1
        bnz     seg_clear_l0
        return

        ;; get_digit - get the bitmask for a given digit
        ;; @W: digit
        ;;
        ;; Get the 7seg display bitmask for the digit in W.
        ;; If the LEADING flag is set return an empty bitmask.
        ;; The lower point in the 7seg display is the 7th bit
        ;; with a bitmask of 0x80.
        ;;
        ;; Return: W = 7seg bitmask
get_digit:
        andlw   0x0F
        bnz     get_digit_l0
        btfsc   flags, LEADING, B
        retlw   0
get_digit_l0:
        ltabw   get_digit_l1
        tblrd   *
        movf    TABLAT, W, A
        bcf     flags, LEADING, B
        return
get_digit_l1:
        db      0x3F,0x06,0x5B,0x4F ; 0, 1, 2, 3
        db      0x66,0x6D,0x7D,0x07 ; 4, 5, 6, 7
        db      0x7F,0x6F,0x77,0x7C ; 8, 9, 0, A
        db      0x39,0x5E,0x79,0x71 ; B, C, D, F

        ;; get_switches - sample the keys' status
        ;;
        ;; Take the values in dbuf and combine them
        ;; into one value by ANDing each one. The
        ;; result is saved into the button variable
        ;;
        ;; Return: no value
get_switches:
        movlw   10
        movwf   tmp, B
        lfsr    FSR0, bstate
        movlw   0xff
get_switches_l0:
        andwf   POSTINC0, W, A
        decfsz  tmp, F, B
        bra     get_switches_l0
        movwf   button, B
        return

        ;; get_repeat - detect if a key was pushed
        ;; @W: 1<<button
        ;;
        ;; Detect if a key was pushed or if enough time
        ;; passed to fire it again.
        ;;
        ;; Return: Carry Flag set if key was pushed
get_repeat:
        bcf     STATUS, C, A
        andwf   button+0, W, B
        bz      get_repeat_skip
        andwf   button+1, W, B
        bz      get_repeat_first
        btfsc   flags, REPEAT, B
        bra     get_repeat_signal
        bra     get_repeat_skip
get_repeat_first:
        movlw   TDELAY
        movwf   tdel, B
get_repeat_signal:
        bcf     flags, REPEAT, B
        bsf     STATUS, C, A
get_repeat_skip:
        return

        ;; read_eeprom - read the current slot values from eeprom
        ;;
        ;; Read the timeout and rmask values from the current
        ;; slot in EEPROM.
        ;;
        ;; Return: no value
read_eeprom:
        lfsr    FSR0, timeout
        rlncf   slot, W, B
        addwf   slot, W, B
        addlw   saved
        movwf   EEADR, A        ; addr = saved + slot * 3
        bcf     EECON1, EEPGD, A
        bcf     EECON1, CFGS, A
        movlw   3
        movwf   tmp, B
read_eeprom_l0:
        bsf     EECON1, RD, A
        movf    EEDATA, W, A
        movwf   POSTINC0, A
        incf    EEADR, F, A
        decfsz  tmp, F, B
        bra     read_eeprom_l0
        return

        ;; update_eeprom - save the slot data in eeprom
        ;;
        ;; Update the current slot with the values stored
        ;; in timeout and rmask, but only if they differ.
        ;;
        ;; Return: no value
update_eeprom:
        lfsr    FSR0, timeout
        rlncf   slot, W, B
        addwf   slot, W, B
        addlw   saved
        movwf   EEADR, A        ; addr = saved + slot * 3
        movlw   3
        movwf   tmp, B
        bcf     EECON1, CFGS, A
        bcf     EECON1, EEPGD, A
        bsf     EECON1, WREN, A
        bcf     INTCON, GIE, A
update_eeprom_l1:
        bsf     EECON1, RD, A
        movf    EEDATA, W, A
        subwf   INDF0, W, A
        bz      update_eeprom_l2
        movf    INDF0, W, A
        movwf   EEDATA, A
        movlw   0x55
        movwf   EECON2, A
        movlw   0xAA
        movwf   EECON2, A
        bsf     EECON1, WR, A
        btfsc   EECON1, WR, A   ; wait for write to complete
        bra     $-2
update_eeprom_l2:
        movf    POSTINC0, W, A
        incf    EEADR, F, A
        decfsz  tmp, F, B
        bra     update_eeprom_l1

        bcf     EECON1, WREN, A
        bsf     INTCON, GIE, A
        return

        ;; b16_d5 - convert a 16bit value to BCD
        ;; @FSR0: address of the 16bit value [LSB, MSB]
        ;;
        ;; Convert a 16bit value pointed by FSR0 into
        ;; 5 digits BCD values saved in
        ;;  tmp, dbuf[0], dbuf[2], dbuf[6], dbuf[8]
        ;;
        ;; for the theory please have a look at
        ;; http://www.piclist.com/techref/microchip/math/radix/b2bu-16b5d.htm
        ;;
        ;; Return: 0
b16_d5:
        movf    POSTINC0, W, A  ; we have to start from MSB
        swapf   INDF0, W, A     ; W  = A2*16 + A3
        iorlw   0xF0            ; W  = A3 - 16
        movwf   dbuf+0, B       ; B3 = A3 - 16
        addwf   dbuf+0, F, B    ; B3 = 2*(A3 - 16) = 2A3 - 32
        addlw   226             ; W  = A3 - 16 - 30 = A3 - 46
        movwf   dbuf+2, B       ; B2 = A3 - 46
        addlw   50              ; W  = A3 - 40 + 50 = A3 + 4
        movwf   dbuf+8, B       ; B0 = A3 + 4

        movf    POSTDEC0, W, A  ; W  = A3 * 16 + A2
        andlw   0x0F            ; W  = A2
        addwf   dbuf+2, F, B    ; B2 = A3 + A2 - 46
        addwf   dbuf+2, F, B    ; B2 = A3 + 2A2 - 46
        addwf   dbuf+8, F, B    ; B0 = A3 + A2 + 4
        addlw   233             ; W  = A2 - 23
        movwf   dbuf+6, B       ; B1 = A2 - 23
        addwf   dbuf+6, F, B    ; B1 = 2*(A2 - 23) = 2A2 - 46
        addwf   dbuf+6, F, B    ; B1 = 3*(A2 - 23) = 3A2 - 69

        swapf   INDF0, W, A     ; W  = A0 * 16 + A1
        andlw   0x0F            ; W  = A1
        addwf   dbuf+6, F, B    ; B1 = 3A2 + A1 - 69
        addwf   dbuf+8, F, B    ; B0 = A3 + A2 + A1 + 4 (C = 0)

        rlcf    dbuf+6, F, B    ; B1 = 2*(3A2 + A1 - 69) = 6A2 + 2A1 - 138 (C = 1)
        rlcf    dbuf+8, F, B    ; B0 = 2*(A3+A2+A1+4)+C = 2A3+2A2+2A1+9
        comf    dbuf+8, F, B    ; B0 = ~(2A3+2A2+2A1+9)= -2A3-2A2-2A1-10
        rlcf    dbuf+8, F, B    ; B0 = 2*(-2A3-2A2-2A1-10) = -4A3-4A2-4A1-20

        movf    INDF0, W, A     ; W  = A1*16+A0
        andlw   0x0F            ; W  = A0
        addwf   dbuf+8, F, B    ; B0 = A0-4A3-4A2-4A1-20 (C=0)
        rlcf    dbuf+0, F, B    ; B3 = 2*(2A3-32) = 4A3 - 64

        movlw   0x07            ; W  = 7
        movwf   tmp, B          ; B4 = 7

        ;; normalization
        ;; B0 = A0-4(A3+A2+A1)-20 range  -5 .. -200
        ;; B1 = 6A2+2A1-138       range -18 .. -138
        ;; B2 = A3+2A2-46         range  -1 ..  -46
        ;; B3 = 4A3-64            range  -4 ..  -64
        ;; B4 = 7                 7
        movlw   10              ; W  = 10
b16_d5_lb1:                     ; do {
        decf    dbuf+6, F, B    ;   B1 -= 1
        addwf   dbuf+8, F, B    ;   B0 += 10
        skpc                    ; } while B0 < 0
        bra     b16_d5_lb1
b16_d5_lb2:                     ; do {
        decf    dbuf+2, F, B    ;  B2 -= 1
        addwf   dbuf+6, F, B    ;  B1 += 10
        skpc                    ; } while B1 < 0
        bra     b16_d5_lb2
b16_d5_lb3:                     ; do {
        decf    dbuf+0, F, B    ;  B3 -= 1
        addwf   dbuf+2, F, B    ;  B2 += 10
        skpc                    ; } while B2 < 0
        bra     b16_d5_lb3
b16_d5_lb4:                     ; do {
        decf    tmp, F, B       ;  B4 -= 1
        addwf   dbuf+0, F, B    ;  B3 += 10
        skpc                    ; } while B3 < 0
        bra     b16_d5_lb4
        retlw   0

        end
