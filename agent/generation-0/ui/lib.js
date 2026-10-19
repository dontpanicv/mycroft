// Shared pieces of the screen: access to the app, navigation, formatting, markdown and icons.

import { html, createContext, useContext, useState, useEffect, useRef, useCallback } from '/lib/preact.js'

export const Runtime = createContext(null)
export const useRuntime = () => useContext(Runtime)

/** Calls the app; see README.md for the ops. */
export function useCall() {
	return useRuntime().call
}

/** A slice of what the app reported, re-rendering when it changes: useData((d) => d.state?.threads ?? []). */
export function useData(select) {
	const { data } = useRuntime()
	const [value, setValue] = useState(() => select(data.get()))
	const selectRef = useRef(select)
	selectRef.current = select
	useEffect(() => data.subscribe((next) => setValue(() => selectRef.current(next))), [data])
	return value
}

/** The screen's own saved state (it survives reloads): const [drafts, setDrafts] = useUI('drafts', {}). */
export function useUI(key, initial) {
	const { ui } = useRuntime()
	const [value, setValue] = useState(() => ui.get()[key] ?? initial)
	useEffect(() => ui.subscribe((next) => setValue(next[key] ?? initial)), [ui, key])
	const set = useCallback(
		(next) => ui.set((current) => ({ [key]: typeof next === 'function' ? next(current[key] ?? initial) : next })),
		[ui, key],
	)
	return [value, set]
}

// MARK: Navigation — a stack of hash routes kept in the UI state (not browser history, which a reload would break).

export function useNavigation() {
	const { ui } = useRuntime()
	const [stack] = useUI('stack', ['#/'])
	const go = useCallback((route) => ui.set((current) => ({ stack: [...(current.stack ?? ['#/']), route], back: false })), [ui])
	const back = useCallback(
		() => ui.set((current) => ({ stack: (current.stack ?? ['#/']).length > 1 ? current.stack.slice(0, -1) : ['#/'], back: true })),
		[ui],
	)
	const replace = useCallback((route) => ui.set((current) => ({ stack: [...(current.stack ?? ['#/']).slice(0, -1), route] })), [ui])
	return { route: stack[stack.length - 1], depth: stack.length, go, back, replace }
}

// MARK: Formatting

export const pad = (n) => String(n).padStart(2, '0')

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto', style: 'short' })
export function ago(date) {
	const seconds = (new Date(date).getTime() - Date.now()) / 1000
	const steps = [[60, 'second'], [60, 'minute'], [24, 'hour'], [7, 'day'], [4.35, 'week'], [12, 'month'], [Infinity, 'year']]
	let value = seconds
	for (const [size, unit] of steps) {
		if (Math.abs(value) < size) return unit === 'second' ? 'now' : relative.format(Math.round(value), unit)
		value /= size
	}
}

export function duration(ms) {
	if (ms == null) return ''
	if (ms < 1000) return `${Math.round(ms)}ms`
	if (ms < 60_000) return `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)}s`
	return `${Math.floor(ms / 60_000)}m${pad(Math.round((ms % 60_000) / 1000))}s`
}

/** The one argument worth showing for a tool call. */
export function summarize(args) {
	if (!args || typeof args !== 'object') return ''
	for (const key of ['command', 'goal', 'path', 'route', 'operation', 'query', 'url', 'text', 'note', 'machine']) {
		if (typeof args[key] === 'string' && args[key]) return args[key].replace(/\s+/g, ' ')
	}
	const first = Object.keys(args).sort()[0]
	if (first === undefined) return ''
	const value = args[first]
	return (typeof value === 'string' ? value : JSON.stringify(value)).replace(/\s+/g, ' ')
}

// MARK: Markdown — small and strict: everything is escaped, only a few tags come out, links only to http(s).

const escape = (text) => text.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])

function inline(text) {
	const codes = []
	let out = escape(text).replace(/`([^`]+)`/g, (_, code) => `\u0000${codes.push(code) - 1}\u0000`)
	out = out
		.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>')
		.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2">$2</a>')
		.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
		.replace(/(^|[^*\w])\*([^*\s][^*]*)\*(?!\w)/g, '$1<em>$2</em>')
		.replace(/(^|[^_\w])_([^_\s][^_]*)_(?!\w)/g, '$1<em>$2</em>')
	return out.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[i]}</code>`)
}

export function markdown(source) {
	const lines = source.replace(/\r\n/g, '\n').split('\n')
	const out = []
	let paragraph = []
	let list = null
	const flush = () => {
		if (paragraph.length) out.push(`<p>${inline(paragraph.join('\n')).replace(/\n/g, '<br>')}</p>`)
		paragraph = []
		if (list) out.push(`<${list.tag}>${list.items.map((item) => `<li>${inline(item)}</li>`).join('')}</${list.tag}>`)
		list = null
	}
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i]
		const fence = line.match(/^\s*```(\S*)/)
		if (fence) {
			flush()
			const code = []
			while (++i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i])
			out.push(`<pre><code>${escape(code.join('\n'))}</code></pre>`)
			continue
		}
		const heading = line.match(/^(#{1,4})\s+(.*)/)
		const bullet = line.match(/^\s*[-*•]\s+(.*)/)
		const numbered = line.match(/^\s*\d+[.)]\s+(.*)/)
		const quote = line.match(/^>\s?(.*)/)
		if (heading) {
			flush()
			out.push(`<h${heading[1].length + 2}>${inline(heading[2])}</h${heading[1].length + 2}>`)
		} else if (bullet || numbered) {
			const tag = bullet ? 'ul' : 'ol'
			if (paragraph.length || (list && list.tag !== tag)) flush()
			list = list ?? { tag, items: [] }
			list.items.push((bullet ?? numbered)[1])
		} else if (quote) {
			flush()
			out.push(`<blockquote>${inline(quote[1])}</blockquote>`)
		} else if (!line.trim()) {
			flush()
		} else if (list && /^\s{2,}\S/.test(line)) {
			list.items[list.items.length - 1] += ' ' + line.trim()
		} else {
			if (list) flush()
			paragraph.push(line)
		}
	}
	flush()
	return out.join('')
}

export function Markdown({ text, class: className = 'prose' }) {
	return html`<div class=${className} dangerouslySetInnerHTML=${{ __html: markdown(text) }} />`
}

// MARK: Icons — 24×24 strokes in the current colour.

const paths = {
	gear: 'M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4Z M19.4 13.5l1.6 1.2-1.8 3.1-1.9-.6a7.6 7.6 0 0 1-2 1.2l-.4 2h-3.6l-.4-2a7.6 7.6 0 0 1-2-1.2l-1.9.6-1.8-3.1 1.6-1.2a7.4 7.4 0 0 1 0-3l-1.6-1.2 1.8-3.1 1.9.6a7.6 7.6 0 0 1 2-1.2l.4-2h3.6l.4 2a7.6 7.6 0 0 1 2 1.2l1.9-.6 1.8 3.1-1.6 1.2a7.4 7.4 0 0 1 0 3Z',
	plus: 'M12 5v14 M5 12h14',
	wave: 'M4 10v4 M8 7v10 M12 4v16 M16 8v8 M20 10v4',
	mic: 'M12 15a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v6a3 3 0 0 0 3 3Z M18.5 11.5a6.5 6.5 0 0 1-13 0 M12 18v3',
	up: 'M12 19V5 M6 11l6-6 6 6',
	stop: 'M7 7h10v10H7Z',
	back: 'M15 5l-7 7 7 7',
	chevron: 'M9 6l6 6-6 6',
	down: 'M6 9l6 6 6-6',
	out: 'M8 16 16 8 M9 8h7v7',
	close: 'M6 6l12 12 M18 6 6 18',
	check: 'M5 12.5l4.5 4.5L19 7.5',
	copy: 'M9 9h10v10H9Z M5 15V5h10',
	machine: 'M4 5h16v10H4Z M9 19h6 M12 15v4',
	trash: 'M4 7h16 M9 7V4h6v3 M6 7l1 13h10l1-13 M10 11v6 M14 11v6',
	lock: 'M6 11h12v9H6Z M8.5 11V8a3.5 3.5 0 0 1 7 0v3',
	queue: 'M9 6h11 M9 12h11 M9 18h11 M4 6h.01 M4 12h.01 M4 18h.01',
	steer: 'M9 14 4 9l5-5 M4 9h10.5a5.5 5.5 0 0 1 0 11H11',
	play: 'M7 5v14l11-7Z',
	retry: 'M4 12a8 8 0 1 0 2.4-5.7 M4 4v4h4',
	fork: 'M7 3v6a5 5 0 0 0 5 5 M17 3v6a5 5 0 0 1-5 5v7',
	pin: 'M9 4h6l-1 6 4 4H6l4-4Z M12 14v6',
	archive: 'M4 5h16v4H4Z M5 9v10h14V9 M10 13h4',
	pencil: 'M15 5l4 4L8 20H4v-4Z',
}

export function Icon({ name, size = 20, stroke = 1.8 }) {
	return html`<svg class="icon" width=${size} height=${size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
		stroke-width=${stroke} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
		<path d=${paths[name]} />
	</svg>`
}

/** An uppercase, tracked mono label: grep.ai's section labels. */
export function Label({ children, tone, size }) {
	return html`<span class=${`label ${tone ?? ''}`} style=${size ? `font-size:${size}px` : ''}>${children}</span>`
}

/** A square hairline tag: RUNNING, PHONE, GEN 3. */
export function Tag({ children, tone }) {
	return html`<span class=${`tag ${tone ?? ''}`}>${children}</span>`
}

export function Spinner() {
	return html`<span class="spinner" aria-hidden="true"></span>`
}

/** Light haptic feedback through the app. */
export function haptic(call, style = 'light') {
	call('haptic', { style }).catch(() => {})
}

/** A glass action sheet from the bottom. */
export function Sheet({ children, onClose }) {
	return html`<div class="sheet-backdrop" onClick=${onClose}>
		<div class="sheet glass" onClick=${(event) => event.stopPropagation()}>${children}</div>
	</div>`
}
