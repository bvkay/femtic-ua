S=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
which make || { echo "NO make in WSL"; exit 0; }
make --version | head -1
run() { echo "----- $*"; "$@" 2>&1 | head -${N:-4}; echo "     [exit ${PIPESTATUS[0]}]"; }
cd $S/femtic/src
N=3 run make -n -f $S/ported/femtic/Makefile.gcc_openmpi_mkl MKLROOT=/opt/dummy/mkl
echo "... last link line:"; make -n -f $S/ported/femtic/Makefile.gcc_openmpi_mkl MKLROOT=/opt/dummy/mkl 2>&1 | tail -1
N=2 run env -u MKLROOT make -n -f $S/ported/femtic/Makefile.gcc_openmpi_mkl
N=2 run env -u MKLROOT make -n -f $S/ported/femtic/Makefile.gcc_openmpi_mkl clean
N=2 run make -n -f $S/ported/femtic/Makefile.intel_oneapi MKLROOT=/opt/dummy/mkl
echo "... last link line:"; make -n -f $S/ported/femtic/Makefile.intel_oneapi MKLROOT=/opt/dummy/mkl 2>&1 | tail -1
echo "... object count in dry run: $(make -n -f $S/ported/femtic/Makefile.gcc_openmpi_mkl MKLROOT=/x 2>/dev/null | grep -c ' -c ')"
cd $S/makeTetraMesh/src
N=2 run make -n -f $S/ported/makeTetraMesh/Makefile.gcc_mkl
echo "... link:"; make -n -f $S/ported/makeTetraMesh/Makefile.gcc_mkl | tail -1
echo "... link WITH_MKL=1:"; make -n -f $S/ported/makeTetraMesh/Makefile.gcc_mkl WITH_MKL=1 MKLROOT=/opt/dummy/mkl | tail -1
N=2 run env -u MKLROOT make -n -f $S/ported/makeTetraMesh/Makefile.gcc_mkl WITH_MKL=1
N=2 run make -n -f $S/ported/makeTetraMesh/Makefile.intel_oneapi
echo "... link:"; make -n -f $S/ported/makeTetraMesh/Makefile.intel_oneapi | tail -1
for t in makeMtr TetGen2Femtic makeDHexaMesh mergeResultOfFEMTIC; do cd $S/$t/src; N=2 run make -n -f $S/ported/$t/Makefile.gcc; echo "... link:"; make -n -f $S/ported/$t/Makefile.gcc | tail -1; done
cd $S/tetgen; echo "----- tetgen upstream makefile as-is (CRLF) dry run:"; make -n tetgen 2>&1 | head -3; echo "----- after CRLF strip (to a temp copy):"; sed 's/\r$//' makefile > /tmp/tetgen.mk; make -n -f /tmp/tetgen.mk tetgen 2>&1 | head -3
