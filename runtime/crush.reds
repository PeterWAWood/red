Red/System [
	Title:   "Compress and decompress algorithms for Red runtime"
	Author:  "Qingtian Xie"
	File: 	 %crush.reds
	Tabs:	 4
	Rights:  "Copyright (C) 2015 Nenad Rakocevic & Xie Qingtian. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/dockimbel/Red/blob/master/BSL-License.txt
	}
	Notes: {
		Thanks for Ilya Muravyov making it in the Public Domain.
		http://sourceforge.net/projects/crush/
	}
]

crush: context [							;-- LZ77

	#define CRUSH_W_BITS 		21			;-- window size (17..23)
	#define CRUSH_W_SIZE 		2097152		;-- 1 << CRUSH_W_BITS
	#define CRUSH_W_MASK 		2097151		;-- CRUSH_W_SIZE - 1
	#define CRUSH_SLOT_BITS 	4
	#define CRUSH_NUM_SLOTS 	16			;-- 1 << CRUSH_SLOT_BITS

	#define CRUSH_A_BITS		2			;-- 1 xx
	#define CRUSH_B_BITS		2			;-- 01 xx
	#define CRUSH_C_BITS		2			;-- 001 xx
	#define CRUSH_D_BITS		3			;-- 0001 xxx
	#define CRUSH_E_BITS		5			;-- 00001 xxxxx
	#define CRUSH_F_BITS		9			;-- 00000 xxxxxxxxx
	#define CRUSH_A				4			;-- 1 << A_BITS;
	#define CRUSH_B				8			;-- (1 << B_BITS) + A
	#define CRUSH_C				12			;-- (1 << C_BITS) + B
	#define CRUSH_D				20			;-- (1 << D_BITS) + C
	#define CRUSH_E				52			;-- (1 << E_BITS) + D
	#define CRUSH_F				564			;-- (1 << F_BITS) + E
	#define CRUSH_MIN_MATCH 	3
	#define CRUSH_MAX_MATCH 	566			;-- (CRUSH_F - 1) + CRUSH_MIN_MATCH
	
	#define CRUSH_BUF_SIZE		67108864	;-- 1 << 26

	#define CRUSH_TOO_FAR		65536		;-- 1 << 16

	#define CRUSH_HASH1_LEN		3			;-- CRUSH_MIN_MATCH
	#define CRUSH_HASH2_LEN		4			;-- CRUSH_MIN_MATCH + 1
	#define CRUSH_HASH1_BITS	21
	#define CRUSH_HASH2_BITS	24
	#define CRUSH_HASH1_SIZE	2097152		;-- 1 << CRUSH_HASH1_BITS
	#define CRUSH_HASH2_SIZE	16777216    ;-- 1 << CRUSH_HASH2_BITS
	#define CRUSH_HASH1_MASK	2097151     ;-- CRUSH_HASH1_SIZE - 1
	#define CRUSH_HASH2_MASK	16777215    ;-- CRUSH_HASH2_SIZE - 1
	#define CRUSH_HASH1_SHIFT	7           ;-- (CRUSH_HASH1_BITS + (CRUSH_HASH1_LEN - 1)) / CRUSH_HASH1_LEN
	#define CRUSH_HASH2_SHIFT	6           ;-- (CRUSH_HASH2_BITS + (CRUSH_HASH2_LEN - 1)) / CRUSH_HASH2_LEN

	crush!: alias struct! [
		bit-buf		[integer!]
		bit-count	[integer!]
		input		[byte-ptr!]
		buf			[byte-ptr!]
		buf-size	[integer!]
		index		[integer!]
	]

	init: func [
		crush	[crush!]
		size	[integer!]
		input	[byte-ptr!]
	][
		crush/input: input
		crush/bit-buf: 0
		crush/bit-count: 0
		crush/index: 0
		crush/buf-size: either input = null [size / 4][size * 6]
		crush/buf: allocate crush/buf-size no
	]

	get-buf: func [
		crush	[crush!]
		size	[integer!]
		return: [byte-ptr!]
		/local
			buf			[byte-ptr!]
			index		[integer!]
			buf-size	[integer!]
	][
		buf: crush/buf
		buf-size: crush/buf-size
		index: crush/index

		if index >= buf-size [
			buf-size: buf-size + 4194304
			buf: allocate buf-size no
			move-memory buf crush/buf crush/buf-size
			free crush/buf
			crush/buf: buf
			crush/buf-size: buf-size
		]

		crush/index: index + size
		buf + index
	]

	put-bits: func [
		n		[integer!]
		x		[integer!]
		crush	[crush!]
		/local
			bit-buf		[integer!]
			bit-count	[integer!]
			buf			[byte-ptr!]
	][
		bit-buf: crush/bit-buf
		bit-count: crush/bit-count

		bit-buf: x << bit-count or bit-buf
		bit-count: bit-count + n
		while [bit-count >= 8][
			buf: get-buf crush 1
			buf/value: as byte! bit-buf
			bit-buf: bit-buf >> 8
			bit-count: bit-count - 8
		]
		crush/bit-buf: bit-buf
		crush/bit-count: bit-count
	]

	get-bits: func [
		n		[integer!]
		crush	[crush!]
		return: [integer!]
		/local
			input		[byte-ptr!]
			data		[integer!]
			bit-buf		[integer!]
			bit-count	[integer!]
	][
		input: crush/input
		bit-buf: crush/bit-buf
		bit-count: crush/bit-count

		while [bit-count < n][
			data: as-integer input/value
			input: input + 1
			bit-buf: data << bit-count or bit-buf
			bit-count: bit-count + 8
		]
		data: 1 << n - 1 and bit-buf
		crush/input: input
		crush/bit-buf: bit-buf >> n
		crush/bit-count: bit-count - n
		data
	]

	update-hash1: func [
		h		[integer!]
		c		[integer!]
		return: [integer!]
	][
		h << CRUSH_HASH1_SHIFT + c and CRUSH_HASH1_MASK
	]

	update-hash2: func [
		h		[integer!]
		c		[integer!]
		return: [integer!]
	][
		h << CRUSH_HASH2_SHIFT + c and CRUSH_HASH2_MASK
	]

	get-penalty: func [
		a		[integer!]
		b		[integer!]
		return: [integer!]
		/local
			p	[integer!]
	][
		p: 0
		while [a > b][
			a: a >> 3
			p: p + 1
		]
		p
	]

	compress: func [
		data	[byte-ptr!]
		length	[integer!]
		written [int-ptr!]
		return: [byte-ptr!]
		/local
			i			[integer!]
			s			[integer!]
			ss			[integer!]
			l			[integer!]
			p			[integer!]
			pp			[integer!]
			h1			[integer!]
			h2			[integer!]
			len			[integer!]
			log			[integer!]
			size		[integer!]
			offset		[integer!]
			max-match	[integer!]
			chain-len	[integer!]
			limit		[integer!]
			hash-size	[integer!]
			head		[int-ptr!]
			prev		[int-ptr!]
			output		[int-ptr!]
			buf			[byte-ptr!]
			continue?	[logic!]
			crush		[crush!]
	][
		hash-size: CRUSH_HASH1_SIZE + CRUSH_HASH2_SIZE
		head: as int-ptr! allocate hash-size * size? integer! no
		prev: as int-ptr! allocate CRUSH_W_SIZE * size? integer! no
		buf: allocate CRUSH_BUF_SIZE no

		crush: declare crush!
		init crush length null

		size: CRUSH_BUF_SIZE
		while [length > 0][
			if length < CRUSH_BUF_SIZE [size: length]
			copy-memory buf data size
			output: as int-ptr! get-buf crush 4
			output/value: size

			i: 1
			until [
				head/i: -1
				i: i + 1
				i > hash-size
			]

			h1: 0
			h2: 0
			i: 1
			until [
				h1: update-hash1 h1 as-integer buf/i
				i: i + 1
				i > CRUSH_HASH1_LEN
			]
			h1: h1 + 1
			i: 1
			until [
				h2: update-hash2 h2 as-integer buf/i
				i: i + 1
				i > CRUSH_HASH2_LEN
			]
			h2: h2 + 1
		
			crush/bit-buf: 0
			crush/bit-count: 0

			p: 0
			while [p < size][
				len: CRUSH_MIN_MATCH - 1
				offset: CRUSH_W_SIZE
				max-match: either CRUSH_MAX_MATCH < (size - p) [CRUSH_MAX_MATCH][size - p]
				limit: either 0 < (p - CRUSH_W_SIZE) [p - CRUSH_W_SIZE][0]

				if head/h1 >= limit [
					s: head/h1
					ss: s + 1
					pp: p + 1
					if buf/ss = buf/pp [
						l: 1
						continue?: yes
						while [all [continue? l < max-match]][
							l: l + 1
							ss: s + l
							pp: p + l
							if buf/ss <> buf/pp [l: l - 1 continue?: no]
						]
						if l > len [
							len: l
							offset: p - s
						]
					]
				]

				if len < CRUSH_MAX_MATCH [
					chain-len: 256
					ss: h2 + CRUSH_HASH1_SIZE
					s: head/ss

					while [all [chain-len <> 0 s >= limit]][
						chain-len: chain-len - 1
						ss: s + len + 1
						pp: p + len + 1
						if buf/ss = buf/pp [
							ss: s + 1
							pp: p + 1
							if buf/ss = buf/pp [
								l: 1
								continue?: yes
								while [all [continue? l < max-match]][
									l: l + 1
									ss: s + l
									pp: p + l
									if buf/ss <> buf/pp [l: l - 1 continue?: no]
								]
								if l > (len + get-penalty p - s >> 4 offset) [
									len: l
									offset: p - s
								]
								if l = max-match [chain-len: 0]
							]
						]
						ss: s and CRUSH_W_MASK + 1
						s: prev/ss
					]
				]

				if all [len = CRUSH_MIN_MATCH offset > CRUSH_TOO_FAR][len: 0]

				either len >= CRUSH_MIN_MATCH [			;-- Match
					put-bits 1 1 crush

					l: len - CRUSH_MIN_MATCH
					case [
						l < CRUSH_A [
							put-bits 1 1 crush
							put-bits CRUSH_A_BITS l crush
						]
						l < CRUSH_B [
							put-bits 2 1 << 1 crush
							put-bits CRUSH_B_BITS l - CRUSH_A crush
						]
						l < CRUSH_C [
							put-bits 3 1 << 2 crush
							put-bits CRUSH_C_BITS l - CRUSH_B crush
						]
						l < CRUSH_D [
							put-bits 4 1 << 3 crush
							put-bits CRUSH_D_BITS l - CRUSH_C crush
						]
						l < CRUSH_E [
							put-bits 5 1 << 4 crush
							put-bits CRUSH_E_BITS l - CRUSH_D crush
						]
						true [
							put-bits 5 0 crush
							put-bits CRUSH_F_BITS l - CRUSH_E crush
						]
					]

					offset: offset - 1
					log: CRUSH_W_BITS - CRUSH_NUM_SLOTS
					while [ss: 2 << log offset >= ss][log: log + 1]
					ss: CRUSH_W_BITS - CRUSH_NUM_SLOTS
					put-bits CRUSH_SLOT_BITS log - ss crush
					either log > ss [
						put-bits log offset - (1 << log) crush
					][
						ss: CRUSH_W_BITS - (CRUSH_NUM_SLOTS - 1)
						put-bits ss offset crush
					]
				][
					len: 1
					pp: p + 1
					put-bits 9 (as-integer buf/pp) << 1 crush
				]

				while [len <> 0][
					len: len - 1
					head/h1: p
					pp: p and CRUSH_W_MASK + 1
					ss: h2 + CRUSH_HASH1_SIZE
					prev/pp: head/ss
					head/ss: p
					p: p + 1
					pp: p + CRUSH_HASH1_LEN
					h1: 1 + update-hash1 h1 - 1 as-integer buf/pp
					pp: p + CRUSH_HASH2_LEN
					h2: 1 + update-hash2 h2 - 1 as-integer buf/pp
				]
			]

			put-bits 7 0 crush
			data: data + size
			length: length - CRUSH_BUF_SIZE
		]

		written/value: crush/index
		crush/buf
	]

	decompress: func [
		data	[byte-ptr!]
		length	[integer!]
		written [int-ptr!]
		return: [byte-ptr!]
		/local
			i			[integer!]
			s			[integer!]
			ss			[integer!]
			p			[integer!]
			pp			[integer!]
			len			[integer!]
			log			[integer!]
			size		[integer!]
			buf			[byte-ptr!]
			head		[int-ptr!]
			p4			[int-ptr!]
			crush		[crush!]
	][
		crush: declare crush!
		init crush length data

		head: as int-ptr! crush/input
		while [
			p4: as int-ptr! crush/input
			size: p4/value
			crush/input: as byte-ptr! p4 + 1
			(as-integer p4 - head) < length
		][
			if any [size < 1 size > CRUSH_BUF_SIZE][
				print-line ["File corrupted: size = " size]
				return null
			]

			crush/bit-buf: 0
			crush/bit-count: 0

			buf: get-buf crush size
			p: 0
			while [p < size][
				either 0 <> get-bits 1 crush [
					len: either 0 <> get-bits 1 crush [
						get-bits CRUSH_A_BITS crush
					][
						either 0 <> get-bits 1 crush [
							CRUSH_A + get-bits CRUSH_B_BITS crush
						][
							either 0 <> get-bits 1 crush [
								CRUSH_B + get-bits CRUSH_C_BITS crush
							][
								either 0 <> get-bits 1 crush [
									CRUSH_C + get-bits CRUSH_D_BITS crush
								][
									either 0 <> get-bits 1 crush [
										CRUSH_D + get-bits CRUSH_E_BITS crush
									][
										CRUSH_E + get-bits CRUSH_F_BITS crush
									]
								]
							]
						]
					]

					ss: CRUSH_W_BITS - CRUSH_NUM_SLOTS
					log: ss + get-bits CRUSH_SLOT_BITS crush
					pp: either log > ss [
						1 << log + get-bits log crush
					][
						get-bits ss + 1 crush
					]
					s: p + not pp
					if s < 0 [
						print-line ["File corrupted: s = " s]
						return null
					]

					p: p + 1
					s: s + 1
					buf/p: buf/s
					p: p + 1
					s: s + 1
					buf/p: buf/s
					p: p + 1
					s: s + 1
					buf/p: buf/s
					while [len <> 0] [
						len: len - 1
						p: p + 1
						s: s + 1
						buf/p: buf/s
					]
				][
					p: p + 1
					buf/p: as byte! get-bits 8 crush
				]
			]
		]

		written/value: crush/index
		crush/buf
	]
]