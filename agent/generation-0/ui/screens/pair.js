// Add a machine: the phone serves a one-line install (already on the clipboard) and waits for it to pair back.

import { html, useEffect } from '/lib/preact.js'
import { useData, useCall, useNavigation, Icon, Label, Spinner, haptic } from '../lib.js'

export function Pair() {
	const call = useCall()
	const { back } = useNavigation()
	const pairing = useData((d) => d.pairing)

	useEffect(() => {
		call('pairing.start').catch(() => {})
		return () => call('pairing.stop').catch(() => {})
	}, [])
	useEffect(() => {
		if (pairing?.state === 'paired') haptic(call, 'success')
	}, [pairing?.state])

	const state = pairing?.state ?? 'starting'
	return html`<main class="screen scroll grid">
		<header class="bar glass-bar">
			<button class="icon-button glass" aria-label="Close" onClick=${back}><${Icon} name="close" /></button>
			<${Label} tone="ink">Add machine<//>
			<span class="bar-side"></span>
		</header>
		<div class="gutter stack">
			${state === 'starting' && html`<div class="center"><${Spinner} /></div>`}
			${state === 'failed' && html`<p class="card danger mono small">${pairing.message}</p>`}
			${state === 'waiting' && html`
				${pairing.localNetwork === 'denied' && html`<p class="card danger small">iOS is blocking Mycroft from your local network, so the computer can't reach this phone. Turn on Settings → Privacy & Security → Local Network → Mycroft, then come back.</p>`}
				<p class="step"><span class="index">01</span><span><b>Open Terminal on your Mac or Linux machine.</b> It must be on the same Wi-Fi as this iPhone.</span></p>
				<p class="step"><span class="index">02</span><span><b>Paste and press Return.</b> ${pairing.copied ? 'The command is on your clipboard. With Universal Clipboard, just paste on the Mac.' : ''}</span></p>
				<pre class="card command" aria-label="Install command">${pairing.command}</pre>
				<div class="row between">
					<button class="button glass" onClick=${() => { call('clipboard.copy', { text: pairing.command }); haptic(call) }}><${Icon} name="copy" size=${15} /> Copy again</button>
					<span class="row gap soft"><${Spinner} /><${Label} size=${10}>Waiting for the machine<//></span>
				</div>
				<p class="faint small">Keep this screen open while it installs. The command works once, for 10 minutes, and only talks to this iPhone.</p>
			`}
			${state === 'paired' && html`
				<${Label} tone="success">Paired<//>
				<h2 class="paired-name">${pairing.machine?.name}</h2>
				<p class="muted mono small">${pairing.machine?.os} ${pairing.machine?.arch} · hands ${pairing.machine?.version}</p>
				<p class="muted">Mycroft can now run commands, edit files and start long jobs there. Mention it by name in a thread.</p>
				<button class="button glass prominent wide" onClick=${back}>Done</button>
			`}
		</div>
	</main>`
}
