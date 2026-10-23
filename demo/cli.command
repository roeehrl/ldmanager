#!/bin/zsh
# The terminal still for the README: real ldm output in the demo VM's Terminal.
# demo/capture.sh crops the window, which this script places at 60,60 (points).
printf '\e[3;60;60t\e[8;27;116t'
ldm() { "/Applications/LD Manager.app/Contents/Helpers/ldm" "$@"; }
p() { print -P "%n@%m %1~ %# $1"; }
clear
p "ldm list --status problems"; ldm list --status problems
echo; p "ldm doctor report"; ldm doctor report
echo; p "ldm explain 78"; ldm explain 78
echo
exec zsh -i
