import glob
import os
import subprocess
import sys

from PIL import Image

stage, version, identity, publisher, out = sys.argv[1:6]
icon = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "icon", "wolium_256.png")
assets = os.path.join(stage, "Assets")
os.makedirs(assets, exist_ok=True)
src = Image.open(icon).convert("RGBA")
for name, size in (("StoreLogo.png", 50), ("Square44x44Logo.png", 44), ("Square150x150Logo.png", 150)):
    src.resize((size, size), Image.LANCZOS).save(os.path.join(assets, name))

manifest = f'''<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap uap5 rescap">
  <Identity Name="{identity}" Publisher="{publisher}" Version="{version}" ProcessorArchitecture="x64"/>
  <Properties>
    <DisplayName>Wolium</DisplayName>
    <PublisherDisplayName>DTSys</PublisherDisplayName>
    <Logo>Assets\\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.22631.0"/>
  </Dependencies>
  <Resources>
    <Resource Language="en-us"/>
    <Resource Language="ru-ru"/>
  </Resources>
  <Applications>
    <Application Id="Wolium" Executable="trackwolium.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="Wolium" Description="Private activity tracker" BackgroundColor="transparent" Square150x150Logo="Assets\\Square150x150Logo.png" Square44x44Logo="Assets\\Square44x44Logo.png"/>
      <Extensions>
        <uap5:Extension Category="windows.startupTask" Executable="trackwolium.exe" EntryPoint="Windows.FullTrustApplication">
          <uap5:StartupTask TaskId="WoliumStartup" Enabled="false" DisplayName="Wolium"/>
        </uap5:Extension>
      </Extensions>
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust"/>
  </Capabilities>
</Package>
'''
with open(os.path.join(stage, "AppxManifest.xml"), "w", encoding="utf-8") as f:
    f.write(manifest)

tools = sorted(glob.glob(r"C:\Program Files (x86)\Windows Kits\10\bin\*\x64\makeappx.exe"))
if not tools:
    sys.exit("makeappx.exe not found")
subprocess.check_call([tools[-1], "pack", "/o", "/d", stage, "/p", out])
