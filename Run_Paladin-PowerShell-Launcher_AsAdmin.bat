@echo off
:: PowerShell Admin Wrapper
:: Generated for: Paladin-PowerShell-Launcher.ps1
:: Paladin Business Consulting
:: Created: 3/23/2026

set "PS1PATH=%~dp0Paladin-PowerShell-Launcher.ps1"
set "SELF_PATH=%~f0"
set "WRAP_VERBOSE=1"


:: Check for admin privileges
net session >nul 2>&1
if %errorLevel% == 0 (
    echo Running with administrator privileges...
    echo.
    if "%WRAP_VERBOSE%"=="1" (
        echo [DIAG] Wrapper: %~nx0
        echo [DIAG] PS1PATH: %PS1PATH%
        echo [DIAG] User: %USERNAME%  Domain: %USERDOMAIN%  Computer: %COMPUTERNAME%
        echo [DIAG] Elevation: OK
        echo.
        powershell -NoProfile -ExecutionPolicy Bypass -Command "$PSVersionTable | Out-String | Write-Host"
        echo.
    )
    ) else (
    echo Requesting administrator privileges...
    echo.
    :: Re-run with admin rights
    powershell -Command "Start-Process $env:SELF_PATH -Verb RunAs"
    exit /b
)

:: Change to script directory
cd /d "%~dp0"

:: Unblock files (remove "downloaded from internet" warning)
echo Unblocking files...
set "UNBLOCK_BAT=%~f0"
set "UNBLOCK_PS1=%~dp0Paladin-PowerShell-Launcher.ps1"
powershell -Command "Unblock-File -LiteralPath $env:UNBLOCK_BAT -ErrorAction SilentlyContinue"
powershell -Command "Unblock-File -LiteralPath $env:UNBLOCK_PS1 -ErrorAction SilentlyContinue"
echo.
:: Code-sign PowerShell script
echo Checking code-signing certificate: Charles Hayes
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $Signer='Charles Hayes'; $AutoCreate=[bool]([int]1); $TrustLM=[bool]([int]1); $SkipIfValid=[bool]([int]1); $Verbose=[bool]([int]$env:WRAP_VERBOSE); $CU_My='Cert:\CurrentUser\My'; $LM_My='Cert:\LocalMachine\My'; $Path=$env:PS1PATH; if($Verbose){ Write-Host ('[DIAG] Signer: '+$Signer); Write-Host ('[DIAG] AutoCreate: '+$AutoCreate+'  TrustLM: '+$TrustLM+'  SkipIfValid: '+$SkipIfValid); Write-Host ('[DIAG] PS1PATH: '+$Path); }; if([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)){ throw ('PS1PATH not set or file missing: '+$Path) }; if($SkipIfValid){ $sig0=Get-AuthenticodeSignature -FilePath $Path; if($sig0.Status -eq 'Valid' -and $sig0.SignerCertificate -and $sig0.SignerCertificate.Subject -like ('CN='+$Signer+'*')){ Write-Host ('Already signed -- skipping: '+$sig0.SignerCertificate.Subject); exit 0 } elseif($Verbose){ Write-Host ('[DIAG] Existing sig status: '+$sig0.Status) } }; $Cert=$null; foreach($s in @($CU_My,$LM_My)){ $Cert=Get-ChildItem -Path $s -CodeSigningCert -EA SilentlyContinue | Where-Object { $_.Subject -like ('CN='+$Signer+'*') } | Sort-Object NotAfter -Descending | Select-Object -First 1; if($Cert){break} }; function Add-Trust($c,$Scope){ $thumb=$c.Thumbprint; foreach($storeName in @('TrustedPublisher','Root')){ $sp='Cert:\'+$Scope+'\'+$storeName; $exists=Get-ChildItem -Path $sp -EA SilentlyContinue | Where-Object Thumbprint -eq $thumb | Select-Object -First 1; if(-not $exists){ $cer=Join-Path $env:TEMP ($thumb+'.cer'); Export-Certificate -Cert $c -FilePath $cer | Out-Null; if($Verbose){ Write-Host ('[DIAG] Trusting cert: '+$Scope+'\'+$storeName) }; if($Scope -eq 'CurrentUser'){ Import-Certificate -FilePath $cer -CertStoreLocation $sp -EA Stop | Out-Null } else { $r=Start-Process certutil.exe -ArgumentList ('-f','-addstore',$storeName,$cer) -Wait -NoNewWindow -PassThru; if($r.ExitCode -ne 0){ throw ('certutil failed: exit '+$r.ExitCode) } }; Remove-Item $cer -EA SilentlyContinue } } }; if(-not $Cert -and $AutoCreate){ $Cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject ('CN='+$Signer) -CertStoreLocation $CU_My -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm sha256 -NotAfter (Get-Date).AddYears(10) }; if(-not $Cert){ throw 'No code-signing cert found.' }; Add-Trust $Cert 'CurrentUser'; if($TrustLM){ Add-Trust $Cert 'LocalMachine' }; $null=Set-AuthenticodeSignature -FilePath $Path -Certificate $Cert; $sig=Get-AuthenticodeSignature -FilePath $Path; if($sig.Status -ne 'Valid'){ throw ('Signature failed: '+$sig.Status) }; Write-Host ('Signed OK: '+$Cert.Subject)"
if %errorlevel% neq 0 (
  echo.
  echo Signing failed. Aborting.
  exit /b 87
)
echo.
:: Run PowerShell script
echo Executing: Paladin-PowerShell-Launcher.ps1
echo.
powershell.exe -Sta -ExecutionPolicy AllSigned -NoProfile -File "%PS1PATH%"

:: Capture exit code
set EXIT_CODE=%ERRORLEVEL%

echo.
echo Script completed with exit code: %EXIT_CODE%
echo.
echo Press any key to close...
pause >nul
exit /b %EXIT_CODE%
