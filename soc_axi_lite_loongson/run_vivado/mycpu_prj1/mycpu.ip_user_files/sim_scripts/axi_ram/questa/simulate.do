onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib axi_ram_opt

do {wave.do}

view wave
view structure
view signals

do {axi_ram.udo}

run -all

quit -force
