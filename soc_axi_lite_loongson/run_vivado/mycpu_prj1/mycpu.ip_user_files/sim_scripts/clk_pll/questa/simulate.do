onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib clk_pll_opt

do {wave.do}

view wave
view structure
view signals

do {clk_pll.udo}

run -all

quit -force
