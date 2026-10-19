// Add a machine: the phone serves a short install command (already on the clipboard) on every network it is on, and
// waits for the machine to pair back. The picker chooses which of the phone's addresses the command uses.

import { html, useEffect, useState } from '/lib/preact.js'
import { useData, useUI, useCall, useNavigation, Icon, Label, Spinner, haptic } from '../lib.js'

const reach = {
	'Wi-Fi': 'on the same Wi-Fi as this iPhone',
	Ethernet: 'on the same network as this iPhone',
	Tailscale: 'on your tailnet',
	NetBird: 'in your NetBird network, with a policy that lets it reach this iPhone',
	'Personal Hotspot': "joined to this iPhone's hotspot",
}

export function Pair() {
	const call = useCall()
	const { back } = useNavigation()
	const pairing = useData((d) => d.pairing)
	const [network, setNetwork] = useUI('pairNetwork', null)
	const [pinnedCopied, setPinnedCopied] = useState(false)

	useEffect(() => {
		call('pairing.start', { prefer: network }).catch(() => {})
		return () => call('pairing.stop').catch(() => {})
	}, [])
	useEffect(() => {
		if (pairing?.state === 'paired') haptic(call, 'success')
	}, [pairing?.state])

	const state = pairing?.state ?? 'starting'
	const addresses = pairing?.addresses ?? []
	const chosen = addresses.find((a) => a.ip === pairing?.chosen) ?? addresses[0]
	const choose = (ip) => {
		const address = addresses.find((a) => a.ip === ip)
		if (!address) return
		setNetwork(address.network)
		setPinnedCopied(false)
		call('pairing.choose', { ip }).catch(() => {})
		haptic(call)
	}
	const copyPinned = () => {
		call('clipboard.copy', { text: pairing.pinned })
		setPinnedCopied(true)
		haptic(call)
	}

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
				${pairing.localNetwork === 'denied' && html`<p class="card danger small">iOS is blocking Mycroft from your local network, so a computer on your Wi-Fi can't reach this phone. Turn on Settings → Privacy & Security → Local Network → Mycroft, then come back.</p>`}
				<p class="step"><span class="index">01</span><span><b>Pick the network the machine shares with this iPhone.</b> It must be ${reach[chosen?.network] ?? 'able to reach this address'}.</span></p>
				<label class="picker glass">
					<span class="picker-network">${chosen?.network}</span>
					<span class="picker-ip mono">${chosen?.ip}</span>
					<${Icon} name="down" size=${16} />
					<select aria-label="Network" value=${chosen?.ip} onChange=${(event) => choose(event.target.value)}>
						${addresses.map((a) => html`<option value=${a.ip}>${a.network} · ${a.ip}</option>`)}
					</select>
				</label>
				<p class="step"><span class="index">02</span><span><b>Paste or type this in its terminal, then press Return.</b> ${pairing.copied ? "It's on your clipboard; with Universal Clipboard, just paste on the Mac." : ''}</span></p>
				<pre class="card command short" aria-label="Install command">${pairing.command}</pre>
				<div class="row between">
					<button class="button glass" onClick=${() => { call('clipboard.copy', { text: pairing.command }); haptic(call) }}><${Icon} name="copy" size=${15} /> Copy again</button>
					<span class="row gap soft"><${Spinner} /><${Label} size=${10}>Waiting for the machine<//></span>
				</div>
				<p class="faint small">Keep this screen open while it installs. The code works once, for 10 minutes. The first download trusts the network; everything after it is pinned to this iPhone.</p>
				<p class="faint small">On a network you don't trust, use the pinned command instead. It's longer, but only this iPhone can answer it.</p>
				<button class="button glass small pinned" onClick=${copyPinned}><${Icon} name=${pinnedCopied ? 'check' : 'copy'} size=${13} /> ${pinnedCopied ? 'Pinned command copied' : 'Copy pinned command'}</button>
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
