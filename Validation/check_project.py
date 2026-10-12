"""Portable structural validation only; does not replace xcodebuild."""
import json, pathlib, plistlib, re, xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
s=(root/'BLEInspector.xcodeproj/project.pbxproj').read_text()
s=re.sub(r'//[^\n]*|/\*.*?\*/','',s,flags=re.S)
tokens=re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+',s)
i=0
def value():
 global i
 t=tokens[i]; i+=1
 if t=='{':
  d={}
  while tokens[i]!='}':
   k=tokens[i]; i+=1
   assert tokens[i]=='='; i+=1
   assert k not in d, f'duplicate key {k}'
   d[k]=value(); assert tokens[i]==';'; i+=1
  i+=1; return d
 if t=='(':
  a=[]
  while tokens[i]!=')':
   a.append(value())
   if tokens[i]==',': i+=1
  i+=1; return a
 return json.loads(t) if t.startswith('"') else t
project=value(); assert i==len(tokens)
objects=project['objects']; assert project['rootObject'] in objects
reference_keys={'fileRef','buildConfigurationList','productReference','target','targetProxy','containerPortal','mainGroup','productRefGroup'}
array_keys={'children','targets','buildPhases','dependencies','files','buildConfigurations'}
for oid,obj in objects.items():
 for key,item in obj.items():
  if key in reference_keys: assert item in objects,(oid,key,item)
  if key in array_keys:
   for ref in item: assert ref in objects,(oid,key,ref)
 if obj.get('isa')=='PBXFileReference' and obj.get('sourceTree')=='<group>':
  assert (root/obj['path']).exists(),obj['path']
plist=plistlib.loads((root/'Info.plist').read_bytes()); assert plist['NSBluetoothAlwaysUsageDescription']
for file in root.rglob('*.json'):
 if '.build' not in file.parts: json.loads(file.read_text())
ET.parse(root/'BLEInspector.xcodeproj/xcshareddata/xcschemes/BLEInspector.xcscheme')
sources='\n'.join(p.read_text() for p in (root/'Sources').glob('*.swift'))
assert 'writeValue(' not in sources
assert 'MAC：iOS 不可获取' in sources
print(f'PASS: {len(objects)} PBX objects, all references/files, plist, scheme, JSON resources, no writeValue calls')
