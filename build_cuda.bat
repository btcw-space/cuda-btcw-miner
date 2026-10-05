@echo off
setlocal
cd /d "%~dp0"
where nvcc >nul 2>&1
if errorlevel 1 (
  echo nvcc was not found. Install the NVIDIA CUDA toolkit and use the x64 Native Tools prompt.
  exit /b 1
)
if not exist release mkdir release
if "%CUDA_ARCH%"=="" set CUDA_ARCH=sm_89
if "%CUDA_MAX_REGS%"=="" set CUDA_MAX_REGS=160
if "%CUDA_SIGN_BATCH%"=="" set CUDA_SIGN_BATCH=128
if not "%CUDA_SIGN_BATCH%"=="64" if not "%CUDA_SIGN_BATCH%"=="128" (
  echo CUDA_SIGN_BATCH must be 64 or 128
  exit /b 2
)
echo Building for %CUDA_ARCH%
echo RTX 20 = sm_75    RTX 30 = sm_86    RTX 40 = sm_89    RTX 50 = sm_120
echo RTX 50 needs CUDA 12.8 or newer. Set CUDA_ARCH before running this script.
set OUTPUT=release\btcw_cuda_miner_batch%CUDA_SIGN_BATCH%.exe
nvcc -O3 -std=c++17 -arch=%CUDA_ARCH% --maxrregcount %CUDA_MAX_REGS% -DBTCW_SIGN_BATCH=%CUDA_SIGN_BATCH% -Xptxas=-v,-warn-spills btcw_cuda_miner.cu -o "%OUTPUT%"
if errorlevel 1 exit /b 1
copy /y "%OUTPUT%" release\btcw_cuda_miner.exe >nul
echo Built %OUTPUT%
echo Run: release\btcw_cuda_miner.exe
endlocal
