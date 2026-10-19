// Settings: the ChatGPT sign-in, API keys, Mycroft's generations, paired machines, notices.

import { html, useEffect, useState } from '/lib/preact.js'
import { useData, useCall, useNavigation, Icon, Label, Tag, Spinner, pad, ago, haptic } from '../lib.js'

function Page({ title, children }) {
	const { back } = useNavigation()
	return html`<main class="screen scroll">
		<header class="bar glass-bar">
			<button class="icon-button glass" aria-label="Back" onClick=${back}><${Icon} name="back" /></button>
			<${Label} tone="ink">${title}<//>
			<span class="bar-side"></span>
		</header>
		<div class="gutter stack">${children}</div>
		<div class="spacer"></div>
	</main>`
}

function Section({ title, children }) {
	return html`<section class="section"><${Label}>${title}<//>${children}</section>`
}

export function Settings() {
	const state = useData((d) => d.state)
	return html`<${Page} title="Settings">
		<${Section} title="Model"><${SignIn} /><//>
		<${Section} title="Live voice · GPT-Live">
			<${KeyField} name="openai" saved=${state?.keys?.openai}
				about="Live voice uses OpenAI's GPT-Live, which needs a platform API key (the ChatGPT subscription doesn't cover it). Without one, voice runs on this iPhone: on-device transcription and speech." />
		<//>
		<${Section} title="Desktop control · Jev">
			<${KeyField} name="jev" saved=${state?.keys?.jev}
				about="Jev (typesafe.ai) picks the next action on your Mac from its accessibility tree." />
		<//>
		<${Section} title="Self"><${Generations} generation=${state?.generation} /><//>
		<${Section} title="Machines"><${Machines} machines=${state?.machines ?? []} /><//>
		<${Section} title="About"><${About} /><//>
	<//>`
}

/** ChatGPT subscription sign-in with a device code. */
export function SignIn() {
	const call = useCall()
	const signIn = useData((d) => d.state?.signIn ?? { state: 'unknown' })
	const [working, setWorking] = useState(false)
	const start = () => {
		setWorking(true)
		call('signin.start').finally(() => setTimeout(() => setWorking(false), 1500))
	}
	const button = html`<button class="button glass prominent wide" disabled=${working} onClick=${start}>${working ? 'Waiting…' : 'Sign in with ChatGPT'}</button>`
	switch (signIn.state) {
		case 'signedIn':
			return html`<div class="card row between">
				<div><p class="mono strong">ChatGPT</p><p class="muted small">Sol 6.1 is the default for new threads.</p></div>
				<button class="button glass" onClick=${() => call('signin.signOut')}>Sign out</button>
			</div>`
		case 'waiting': {
			const page = new URL(signIn.url)
			return html`<div class="card stack">
				<p class="muted small">Your sign-in code</p>
				<p class="code">${signIn.code}</p>
				<button class="button glass prominent wide" onClick=${() => call('signin.open', { url: signIn.url, code: signIn.code })}>Copy code & open sign-in</button>
				<p class="faint small">Paste the code on the page, approve, then close the page. Or enter it at ${page.host}${page.pathname} on any other device. Keep Mycroft open until it says you're signed in.</p>
				<div class="row gap soft"><${Spinner} /><${Label} size=${10}>Waiting for approval<//></div>
			</div>`
		}
		case 'failed':
			return html`<div class="card stack"><p class="danger mono small">${signIn.message}</p>${button}</div>`
		default:
			return html`<div class="card stack"><p>Sign in with your ChatGPT subscription to use Sol 6.1.</p>${button}</div>`
	}
}

function KeyField({ name, saved, about }) {
	const call = useCall()
	const [value, setValue] = useState('')
	const save = async () => {
		await call('keys.save', { name, value })
		setValue('')
		haptic(call, 'success')
	}
	return html`<div class="card stack">
		<p class="muted small">${about} The key stays in this iPhone's keychain.</p>
		<div class="row gap">
			<input class="input grow" type="password" autocomplete="off" autocapitalize="off" spellcheck="false"
				placeholder=${saved ? 'Key saved — paste to replace' : 'Paste API key'} value=${value} onInput=${(e) => setValue(e.target.value)} />
			<button class="button glass" disabled=${!value && !saved} onClick=${save}>${!value && saved ? 'Remove' : 'Save'}</button>
		</div>
		<${Tag} tone=${saved ? 'success' : ''}>${saved ? 'Key saved' : 'No key'}<//>
	</div>`
}

/** Mycroft's generations, newest first, like a git log. Tap twice to switch to one. */
function Generations({ generation }) {
	const call = useCall()
	const [armed, setArmed] = useState(null)
	if (!generation) return null
	const history = [...generation.history].sort((a, b) => b.generation - a.generation)
	const use = (number) => {
		if (armed !== number) return setArmed(number)
		setArmed(null)
		haptic(call, 'medium')
		call('generation.rollback', { generation: number })
	}
	return html`<div class="card list-card">
		${history.map((record) => html`<div class="gen-row">
			<span class="index">${pad(record.generation)}</span>
			<span class="grow"><span class="block">${record.note}</span><span class="faint mono tiny">${ago(record.createdAt)}</span></span>
			${record.generation === generation.active
				? html`<${Tag} tone="soft">Active<//>`
				: html`<button class=${`button small glass ${armed === record.generation ? 'prominent' : ''}`} onClick=${() => use(record.generation)}>
						${armed === record.generation ? 'Switch?' : record.generation === generation.lastGood ? 'Last good' : 'Use'}</button>`}
		</div>`)}
		<p class="faint small">Shake the phone for the native recovery screen if a generation ever breaks this one.</p>
	</div>`
}

function Machines({ machines }) {
	const call = useCall()
	const { go } = useNavigation()
	const [status, setStatus] = useState({})
	const [menu, setMenu] = useState(null)
	const names = machines.map((m) => m.name).join(',')
	useEffect(() => {
		setStatus({})
		call('machines.check').then(setStatus).catch(() => {})
	}, [names])
	return html`<div class="card list-card">
		${machines.map((machine) => html`<div class="machine-row" onClick=${() => setMenu(menu === machine.name ? null : machine.name)}>
			<div class="row between">
				<span><span class="mono strong block">${machine.name}</span>
					<span class="faint mono tiny">${machine.os === 'macos' ? 'macOS' : machine.os === 'linux' ? 'Linux' : machine.os} · ${machine.arch} · ${machine.addresses?.[0] ?? '?'}:${machine.port}</span></span>
				${status[machine.name] === 'online'
					? html`<${Tag} tone="success">Online<//>`
					: status[machine.name] ? html`<${Tag} tone="danger">Offline<//>` : html`<${Spinner} />`}
			</div>
			${status[machine.name] && status[machine.name] !== 'online' && html`<p class="danger mono tiny">${status[machine.name]}</p>`}
			${menu === machine.name && html`<button class="button small glass danger" onClick=${() => call('machines.forget', { name: machine.name })}>Forget ${machine.name}</button>`}
		</div>`)}
		${!machines.length && html`<p class="muted small">Pair a Mac or a Linux machine to give Mycroft a shell, files, long jobs and desktop control.</p>`}
		<button class="button glass prominent wide" aria-label="Add machine" onClick=${() => go('#/pair')}><${Icon} name="machine" size=${16} /> Add machine</button>
	</div>`
}

function About() {
	const { go } = useNavigation()
	return html`<button class="card row between link-row" onClick=${() => go('#/notices')}>
		<span class="mono small">Open source notices</span><${Icon} name="chevron" size=${14} />
	</button>`
}

export function Notices() {
	const call = useCall()
	const [text, setText] = useState('')
	useEffect(() => { call('notices.thirdParty').then(setText) }, [])
	return html`<${Page} title="Notices"><pre class="notices">${text}</pre><//>`
}
