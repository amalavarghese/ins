# Define the JDK download URL
$JdkDownloadUrl = "https://download.oracle.com/java/22/latest/jdk-22_windows-x64_bin.exe"

# Set the installation directory
$InstallDir = "C:\Program Files\Java"

Set-ExecutionPolicy Unrestricted

# Download the JDK installer
Invoke-WebRequest -Uri $JdkDownloadUrl -OutFile "jdk-installer.exe" -UseBasicParsing

# Install the JDK silently
Start-Process -Wait -FilePath "jdk-installer.exe" -ArgumentList "/s INSTALL_SILENT=1 STATIC=0 AUTO_UPDATE=0 WEB_JAVA=1 WEB_JAVA_SECURITY_LEVEL=H WEB_ANALYTICS=0 EULA=0 REBOOT=0 NOSTARTMENU=0 SPONSORS=0 /L C:\jdk-install.log" -Verb RunAs  
# Add JDK bin directory to system PATH
[System.Environment]::SetEnvironmentVariable("PATH", "$InstallDir\bin;$env:PATH", "Machine")

# Clean up the installer
Remove-Item "jdk-installer.exe" -Force
#choco feature enable -n allowGlobalConfirmation
