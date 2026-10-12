import { join } from 'node:path';

const home = process.env.SOPRANO_DESKTOP_HOME;
const support = process.env.SOPRANO_DESKTOP_SUPPORT;
const app = process.env.SOPRANO_DESKTOP_APP;
for (const value of [home, support, app]) {
  if (!value?.startsWith('/')) throw new Error('Desktop installation paths must be absolute');
}
const escape = (value: string) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const agents = [
  { label: 'com.soprano.desktop', args: [join(app!, 'Contents/MacOS/SopranoDesktop')], restart: '<dict><key>SuccessfulExit</key><false/></dict>' },
  { label: 'com.soprano.desktop.statusbar', args: [join(support!, 'bin/sketchybar'), '--config', join(home!, '.config/soprano-desktop/sketchybarrc')], restart: '<true/>' },
  { label: 'com.soprano.desktop.borders', args: ['/bin/bash', join(home!, '.config/soprano-desktop/bordersrc')], restart: '<true/>' },
];
for (const agent of agents) {
  const log = join(home!, 'Library/Logs/Soprano Desktop', agent.label + '.log');
  const content = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${agent.label}</string>
<key>ProgramArguments</key><array>${agent.args.map(arg => `<string>${escape(arg)}</string>`).join('')}</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key>${agent.restart}
<key>ProcessType</key><string>Interactive</string>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>LANG</key><string>en_US.UTF-8</string></dict>
<key>StandardOutPath</key><string>${escape(log)}</string>
<key>StandardErrorPath</key><string>${escape(log)}</string>
</dict></plist>\n`;
  await Bun.write(join(home!, 'Library/LaunchAgents', agent.label + '.plist'), content);
}
