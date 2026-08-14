set terminal pngcairo size 900,560 enhanced font 'Arial,12'
set output 'deliverables/iobench_1wl_walltime_mean_std.png'
set title 'io_bench 1wl wall time (real 3-run data)'
set ylabel 'work region wall time (s)'
set yrange [340:354]
set grid ytics lw 1 lc rgb '#dddddd'
set style data histograms
set style histogram errorbars gap 2 lw 2
set style fill solid 0.75 border rgb '#333333'
set boxwidth 0.65
set key off
set xtics rotate by 0
plot 'deliverables/iobench_1wl_walltime_mean_std.dat' using 2:3:xtic(1) lc rgb '#4c78a8'

set terminal svg size 900,560 enhanced font 'Arial,12'
set output 'deliverables/iobench_1wl_walltime_mean_std.svg'
replot
