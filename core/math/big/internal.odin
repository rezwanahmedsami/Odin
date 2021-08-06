//+ignore
package big

/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-2 license.

	A BigInt implementation in Odin.
	For the theoretical underpinnings, see Knuth's The Art of Computer Programming, Volume 2, section 4.3.
	The code started out as an idiomatic source port of libTomMath, which is in the public domain, with thanks.

	==========================    Low-level routines    ==========================

	IMPORTANT: `internal_*` procedures make certain assumptions about their input.

	The public functions that call them are expected to satisfy their sanity check requirements.
	This allows `internal_*` call `internal_*` without paying this overhead multiple times.

	Where errors can occur, they are of course still checked and returned as appropriate.

	When importing `math:core/big` to implement an involved algorithm of your own, you are welcome
	to use these procedures instead of their public counterparts.

	Most inputs and outputs are expected to be passed an initialized `Int`, for example.
	Exceptions include `quotient` and `remainder`, which are allowed to be `nil` when the calling code doesn't need them.

	Check the comments above each `internal_*` implementation to see what constraints it expects to have met.
*/

import "core:mem"
import "core:intrinsics"

/*
	Low-level addition, unsigned. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest`, `a` and `b` != `nil` and have been initalized.
*/
internal_int_add_unsigned :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	dest := dest; x := a; y := b;

	old_used, min_used, max_used, i: int;

	if x.used < y.used {
		x, y = y, x;
		assert(x.used >= y.used);
	}

	min_used = y.used;
	max_used = x.used;
	old_used = dest.used;

	if err = grow(dest, max(max_used + 1, _DEFAULT_DIGIT_COUNT), false, allocator); err != nil { return err; }
	dest.used = max_used + 1;
	/*
		All parameters have been initialized.
	*/

	/* Zero the carry */
	carry := DIGIT(0);

	#no_bounds_check for i = 0; i < min_used; i += 1 {
		/*
			Compute the sum one _DIGIT at a time.
			dest[i] = a[i] + b[i] + carry;
		*/
		dest.digit[i] = x.digit[i] + y.digit[i] + carry;

		/*
			Compute carry
		*/
		carry = dest.digit[i] >> _DIGIT_BITS;
		/*
			Mask away carry from result digit.
		*/
		dest.digit[i] &= _MASK;
	}

	if min_used != max_used {
		/*
			Now copy higher words, if any, in A+B.
			If A or B has more digits, add those in.
		*/
		#no_bounds_check for ; i < max_used; i += 1 {
			dest.digit[i] = x.digit[i] + carry;
			/*
				Compute carry
			*/
			carry = dest.digit[i] >> _DIGIT_BITS;
			/*
				Mask away carry from result digit.
			*/
			dest.digit[i] &= _MASK;
		}
	}
	/*
		Add remaining carry.
	*/
	dest.digit[i] = carry;

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);
	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);
}

/*
	Low-level addition, signed. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest`, `a` and `b` != `nil` and have been initalized.
*/
internal_int_add_signed :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	x := a; y := b;
	/*
		Handle both negative or both positive.
	*/
	if x.sign == y.sign {
		dest.sign = x.sign;
		return #force_inline internal_int_add_unsigned(dest, x, y, allocator);
	}

	/*
		One positive, the other negative.
		Subtract the one with the greater magnitude from the other.
		The result gets the sign of the one with the greater magnitude.
	*/
	if c, _ := #force_inline cmp_mag(a, b); c == -1 {
		x, y = y, x;
	}

	dest.sign = x.sign;
	return #force_inline internal_int_sub_unsigned(dest, x, y, allocator);
}

/*
	Low-level addition Int+DIGIT, signed. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest` and `a` != `nil` and have been initalized.
		`dest` is large enough (a.used + 1) to fit result.
*/
internal_int_add_digit :: proc(dest, a: ^Int, digit: DIGIT) -> (err: Error) {
	/*
		Fast paths for destination and input Int being the same.
	*/
	if dest == a {
		/*
			Fast path for dest.digit[0] + digit fits in dest.digit[0] without overflow.
		*/
		if dest.sign == .Zero_or_Positive && (dest.digit[0] + digit < _DIGIT_MAX) {
			dest.digit[0] += digit;
			dest.used += 1;
			return clamp(dest);
		}
		/*
			Can be subtracted from dest.digit[0] without underflow.
		*/
		if a.sign == .Negative && (dest.digit[0] > digit) {
			dest.digit[0] -= digit;
			dest.used += 1;
			return clamp(dest);
		}
	}

	/*
		If `a` is negative and `|a|` >= `digit`, call `dest = |a| - digit`
	*/
	if a.sign == .Negative && (a.used > 1 || a.digit[0] >= digit) {
		/*
			Temporarily fix `a`'s sign.
		*/
		a.sign = .Zero_or_Positive;
		/*
			dest = |a| - digit
		*/
		if err =  #force_inline internal_int_add_digit(dest, a, digit); err != nil {
			/*
				Restore a's sign.
			*/
			a.sign = .Negative;
			return err;
		}
		/*
			Restore sign and set `dest` sign.
		*/
		a.sign    = .Negative;
		dest.sign = .Negative;

		return clamp(dest);
	}

	/*
		Remember the currently used number of digits in `dest`.
	*/
	old_used := dest.used;

	/*
		If `a` is positive
	*/
	if a.sign == .Zero_or_Positive {
		/*
			Add digits, use `carry`.
		*/
		i: int;
		carry := digit;
		#no_bounds_check for i = 0; i < a.used; i += 1 {
			dest.digit[i] = a.digit[i] + carry;
			carry = dest.digit[i] >> _DIGIT_BITS;
			dest.digit[i] &= _MASK;
		}
		/*
			Set final carry.
		*/
		dest.digit[i] = carry;
		/*
			Set `dest` size.
		*/
		dest.used = a.used + 1;
	} else {
		/*
			`a` was negative and |a| < digit.
		*/
		dest.used = 1;
		/*
			The result is a single DIGIT.
		*/
		dest.digit[0] = digit - a.digit[0] if a.used == 1 else digit;
	}
	/*
		Sign is always positive.
	*/
	dest.sign = .Zero_or_Positive;

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);	
}

internal_add :: proc { internal_int_add_signed, internal_int_add_digit, };

/*
	Low-level subtraction, dest = number - decrease. Assumes |number| > |decrease|.
	Handbook of Applied Cryptography, algorithm 14.9.

	Assumptions:
		`dest`, `number` and `decrease` != `nil` and have been initalized.
*/
internal_int_sub_unsigned :: proc(dest, number, decrease: ^Int, allocator := context.allocator) -> (err: Error) {
	dest := dest; x := number; y := decrease;
	old_used := dest.used;
	min_used := y.used;
	max_used := x.used;
	i: int;

	if err = grow(dest, max(max_used, _DEFAULT_DIGIT_COUNT), false, allocator); err != nil { return err; }
	dest.used = max_used;
	/*
		All parameters have been initialized.
	*/

	borrow := DIGIT(0);

	#no_bounds_check for i = 0; i < min_used; i += 1 {
		dest.digit[i] = (x.digit[i] - y.digit[i] - borrow);
		/*
			borrow = carry bit of dest[i]
			Note this saves performing an AND operation since if a carry does occur,
			it will propagate all the way to the MSB.
			As a result a single shift is enough to get the carry.
		*/
		borrow = dest.digit[i] >> ((size_of(DIGIT) * 8) - 1);
		/*
			Clear borrow from dest[i].
		*/
		dest.digit[i] &= _MASK;
	}

	/*
		Now copy higher words if any, e.g. if A has more digits than B
	*/
	#no_bounds_check for ; i < max_used; i += 1 {
		dest.digit[i] = x.digit[i] - borrow;
		/*
			borrow = carry bit of dest[i]
			Note this saves performing an AND operation since if a carry does occur,
			it will propagate all the way to the MSB.
			As a result a single shift is enough to get the carry.
		*/
		borrow = dest.digit[i] >> ((size_of(DIGIT) * 8) - 1);
		/*
			Clear borrow from dest[i].
		*/
		dest.digit[i] &= _MASK;
	}

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);
}

/*
	Low-level subtraction, signed. Handbook of Applied Cryptography, algorithm 14.9.
	dest = number - decrease. Assumes |number| > |decrease|.

	Assumptions:
		`dest`, `number` and `decrease` != `nil` and have been initalized.
*/
internal_int_sub_signed :: proc(dest, number, decrease: ^Int, allocator := context.allocator) -> (err: Error) {
	number := number; decrease := decrease;
	if number.sign != decrease.sign {
		/*
			Subtract a negative from a positive, OR subtract a positive from a negative.
			In either case, ADD their magnitudes and use the sign of the first number.
		*/
		dest.sign = number.sign;
		return #force_inline internal_int_add_unsigned(dest, number, decrease, allocator);
	}

	/*
		Subtract a positive from a positive, OR negative from a negative.
		First, take the difference between their magnitudes, then...
	*/
	if c, _ := #force_inline cmp_mag(number, decrease); c == -1 {
		/*
			The second has a larger magnitude.
			The result has the *opposite* sign from the first number.
		*/
		dest.sign = .Negative if number.sign == .Zero_or_Positive else .Zero_or_Positive;
		number, decrease = decrease, number;
	} else {
		/*
			The first has a larger or equal magnitude.
			Copy the sign from the first.
		*/
		dest.sign = number.sign;
	}
	return #force_inline internal_int_sub_unsigned(dest, number, decrease, allocator);
}

/*
	Low-level subtraction, signed. Handbook of Applied Cryptography, algorithm 14.9.
	dest = number - decrease. Assumes |number| > |decrease|.

	Assumptions:
		`dest`, `number` != `nil` and have been initalized.
		`dest` is large enough (number.used + 1) to fit result.
*/
internal_int_sub_digit :: proc(dest, number: ^Int, digit: DIGIT) -> (err: Error) {
	dest := dest; digit := digit;
	/*
		All parameters have been initialized.

		Fast paths for destination and input Int being the same.
	*/
	if dest == number {
		/*
			Fast path for `dest` is negative and unsigned addition doesn't overflow the lowest digit.
		*/
		if dest.sign == .Negative && (dest.digit[0] + digit < _DIGIT_MAX) {
			dest.digit[0] += digit;
			return nil;
		}
		/*
			Can be subtracted from dest.digit[0] without underflow.
		*/
		if number.sign == .Zero_or_Positive && (dest.digit[0] > digit) {
			dest.digit[0] -= digit;
			return nil;
		}
	}

	/*
		If `a` is negative, just do an unsigned addition (with fudged signs).
	*/
	if number.sign == .Negative {
		t := number;
		t.sign = .Zero_or_Positive;

		err =  #force_inline internal_int_add_digit(dest, t, digit);
		dest.sign = .Negative;

		clamp(dest);
		return err;
	}

	old_used := dest.used;

	/*
		if `a`<= digit, simply fix the single digit.
	*/
	if number.used == 1 && (number.digit[0] <= digit) || number.used == 0 {
		dest.digit[0] = digit - number.digit[0] if number.used == 1 else digit;
		dest.sign = .Negative;
		dest.used = 1;
	} else {
		dest.sign = .Zero_or_Positive;
		dest.used = number.used;

		/*
			Subtract with carry.
		*/
		carry := digit;

		#no_bounds_check for i := 0; i < number.used; i += 1 {
			dest.digit[i] = number.digit[i] - carry;
			carry = dest.digit[i] >> (_DIGIT_TYPE_BITS - 1);
			dest.digit[i] &= _MASK;
		}
	}

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	return clamp(dest);
}

internal_sub :: proc { internal_int_sub_signed, internal_int_sub_digit, };

/*
	dest = src  / 2
	dest = src >> 1
*/
internal_int_shr1 :: proc(dest, src: ^Int) -> (err: Error) {
	old_used  := dest.used; dest.used = src.used;
	/*
		Carry
	*/
	fwd_carry := DIGIT(0);

	#no_bounds_check for x := dest.used - 1; x >= 0; x -= 1 {
		/*
			Get the carry for the next iteration.
		*/
		src_digit := src.digit[x];
		carry     := src_digit & 1;
		/*
			Shift the current digit, add in carry and store.
		*/
		dest.digit[x] = (src_digit >> 1) | (fwd_carry << (_DIGIT_BITS - 1));
		/*
			Forward carry to next iteration.
		*/
		fwd_carry = carry;
	}

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	dest.sign = src.sign;
	return clamp(dest);	
}

/*
	dest = src  * 2
	dest = src << 1
*/
internal_int_shl1 :: proc(dest, src: ^Int) -> (err: Error) {
	if err = copy(dest, src); err != nil { return err; }
	/*
		Grow `dest` to accommodate the additional bits.
	*/
	digits_needed := dest.used + 1;
	if err = grow(dest, digits_needed); err != nil { return err; }
	dest.used = digits_needed;

	mask  := (DIGIT(1) << uint(1)) - DIGIT(1);
	shift := DIGIT(_DIGIT_BITS - 1);
	carry := DIGIT(0);

	#no_bounds_check for x:= 0; x < dest.used; x+= 1 {		
		fwd_carry := (dest.digit[x] >> shift) & mask;
		dest.digit[x] = (dest.digit[x] << uint(1) | carry) & _MASK;
		carry = fwd_carry;
	}
	/*
		Use final carry.
	*/
	if carry != 0 {
		dest.digit[dest.used] = carry;
		dest.used += 1;
	}
	return clamp(dest);
}

/*
	Multiply by a DIGIT.
*/
internal_int_mul_digit :: proc(dest, src: ^Int, multiplier: DIGIT, allocator := context.allocator) -> (err: Error) {
	assert(dest != nil && src != nil);

	if multiplier == 0 {
		return zero(dest);
	}
	if multiplier == 1 {
		return copy(dest, src);
	}

	/*
		Power of two?
	*/
	if multiplier == 2 {
		return #force_inline internal_int_shl1(dest, src);
	}
	if is_power_of_two(int(multiplier)) {
		ix: int;
		if ix, err = log(multiplier, 2); err != nil { return err; }
		return shl(dest, src, ix);
	}

	/*
		Ensure `dest` is big enough to hold `src` * `multiplier`.
	*/
	if err = grow(dest, max(src.used + 1, _DEFAULT_DIGIT_COUNT), false, allocator); err != nil { return err; }

	/*
		Save the original used count.
	*/
	old_used := dest.used;
	/*
		Set the sign.
	*/
	dest.sign = src.sign;
	/*
		Set up carry.
	*/
	carry := _WORD(0);
	/*
		Compute columns.
	*/
	ix := 0;
	for ; ix < src.used; ix += 1 {
		/*
			Compute product and carry sum for this term
		*/
		product := carry + _WORD(src.digit[ix]) * _WORD(multiplier);
		/*
			Mask off higher bits to get a single DIGIT.
		*/
		dest.digit[ix] = DIGIT(product & _WORD(_MASK));
		/*
			Send carry into next iteration
		*/
		carry = product >> _DIGIT_BITS;
	}

	/*
		Store final carry [if any] and increment used.
	*/
	dest.digit[ix] = DIGIT(carry);
	dest.used = src.used + 1;

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	return clamp(dest);
}

/*
	High level multiplication (handles sign).
*/
internal_int_mul :: proc(dest, src, multiplier: ^Int, allocator := context.allocator) -> (err: Error) {
	/*
		Early out for `multiplier` is zero; Set `dest` to zero.
	*/
	if multiplier.used == 0 || src.used == 0 { return zero(dest); }

	if src == multiplier {
		/*
			Do we need to square?
		*/
		if        false && src.used >= _SQR_TOOM_CUTOFF {
			/* Use Toom-Cook? */
			// err = s_mp_sqr_toom(a, c);
		} else if false && src.used >= _SQR_KARATSUBA_CUTOFF {
			/* Karatsuba? */
			// err = s_mp_sqr_karatsuba(a, c);
		} else if false && ((src.used * 2) + 1) < _WARRAY &&
		                   src.used < (_MAX_COMBA / 2) {
			/* Fast comba? */
			// err = s_mp_sqr_comba(a, c);
		} else {
			err = _int_sqr(dest, src);
		}
	} else {
		/*
			Can we use the balance method? Check sizes.
			* The smaller one needs to be larger than the Karatsuba cut-off.
			* The bigger one needs to be at least about one `_MUL_KARATSUBA_CUTOFF` bigger
			* to make some sense, but it depends on architecture, OS, position of the
			* stars... so YMMV.
			* Using it to cut the input into slices small enough for _mul_comba
			* was actually slower on the author's machine, but YMMV.
		*/

		min_used := min(src.used, multiplier.used);
		max_used := max(src.used, multiplier.used);
		digits   := src.used + multiplier.used + 1;

		if        false &&  min_used     >= _MUL_KARATSUBA_CUTOFF &&
						    max_used / 2 >= _MUL_KARATSUBA_CUTOFF &&
			/*
				Not much effect was observed below a ratio of 1:2, but again: YMMV.
			*/
							max_used     >= 2 * min_used {
			// err = s_mp_mul_balance(a,b,c);
		} else if false && min_used >= _MUL_TOOM_CUTOFF {
			// err = s_mp_mul_toom(a, b, c);
		} else if false && min_used >= _MUL_KARATSUBA_CUTOFF {
			// err = s_mp_mul_karatsuba(a, b, c);
		} else if digits < _WARRAY && min_used <= _MAX_COMBA {
			/*
				Can we use the fast multiplier?
				* The fast multiplier can be used if the output will
				* have less than MP_WARRAY digits and the number of
				* digits won't affect carry propagation
			*/
			err = _int_mul_comba(dest, src, multiplier, digits);
		} else {
			err = _int_mul(dest, src, multiplier, digits);
		}
	}
	neg := src.sign != multiplier.sign;
	dest.sign = .Negative if dest.used > 0 && neg else .Zero_or_Positive;
	return err;
}

internal_mul :: proc { internal_int_mul, internal_int_mul_digit, };

/*
	divmod.
	Both the quotient and remainder are optional and may be passed a nil.
*/
internal_int_divmod :: proc(quotient, remainder, numerator, denominator: ^Int, allocator := context.allocator) -> (err: Error) {

	if denominator.used == 0 { return .Division_by_Zero; }
	/*
		If numerator < denominator then quotient = 0, remainder = numerator.
	*/
	c: int;
	if c, err = #force_inline cmp_mag(numerator, denominator); c == -1 {
		if remainder != nil {
			if err = copy(remainder, numerator, false, allocator); err != nil { return err; }
		}
		if quotient != nil {
			zero(quotient);
		}
		return nil;
	}

	if false && (denominator.used > 2 * _MUL_KARATSUBA_CUTOFF) && (denominator.used <= (numerator.used/3) * 2) {
		// err = _int_div_recursive(quotient, remainder, numerator, denominator);
	} else {
		when true {
			err = _int_div_school(quotient, remainder, numerator, denominator);
		} else {
			/*
				NOTE(Jeroen): We no longer need or use `_int_div_small`.
				We'll keep it around for a bit until we're reasonably certain div_school is bug free.
				err = _int_div_small(quotient, remainder, numerator, denominator);
			*/
			err = _int_div_small(quotient, remainder, numerator, denominator);
		}
	}
	return;
}

/*
	Single digit division (based on routine from MPI).
	The quotient is optional and may be passed a nil.
*/
internal_int_divmod_digit :: proc(quotient, numerator: ^Int, denominator: DIGIT) -> (remainder: DIGIT, err: Error) {
	/*
		Cannot divide by zero.
	*/
	if denominator == 0 { return 0, .Division_by_Zero; }

	/*
		Quick outs.
	*/
	if denominator == 1 || numerator.used == 0 {
		if quotient != nil {
			return 0, copy(quotient, numerator);
		}
		return 0, err;
	}
	/*
		Power of two?
	*/
	if denominator == 2 {
		if numerator.used > 0 && numerator.digit[0] & 1 != 0 {
			// Remainder is 1 if numerator is odd.
			remainder = 1;
		}
		if quotient == nil {
			return remainder, nil;
		}
		return remainder, shr(quotient, numerator, 1);
	}

	ix: int;
	if is_power_of_two(int(denominator)) {
		ix = 1;
		for ix < _DIGIT_BITS && denominator != (1 << uint(ix)) {
			ix += 1;
		}
		remainder = numerator.digit[0] & ((1 << uint(ix)) - 1);
		if quotient == nil {
			return remainder, nil;
		}

		return remainder, shr(quotient, numerator, int(ix));
	}

	/*
		Three?
	*/
	if denominator == 3 {
		return _int_div_3(quotient, numerator);
	}

	/*
		No easy answer [c'est la vie].  Just division.
	*/
	q := &Int{};

	if err = grow(q, numerator.used); err != nil { return 0, err; }

	q.used = numerator.used;
	q.sign = numerator.sign;

	w := _WORD(0);

	for ix = numerator.used - 1; ix >= 0; ix -= 1 {
		t := DIGIT(0);
		w = (w << _WORD(_DIGIT_BITS) | _WORD(numerator.digit[ix]));
		if w >= _WORD(denominator) {
			t = DIGIT(w / _WORD(denominator));
			w -= _WORD(t) * _WORD(denominator);
		}
		q.digit[ix] = t;
	}
	remainder = DIGIT(w);

	if quotient != nil {
		clamp(q);
		swap(q, quotient);
	}
	destroy(q);
	return remainder, nil;
}

internal_divmod :: proc { internal_int_divmod, internal_int_divmod_digit, };

/*
	Asssumes quotient, numerator and denominator to have been initialized and not to be nil.
*/
internal_int_div :: proc(quotient, numerator, denominator: ^Int) -> (err: Error) {
	return #force_inline internal_int_divmod(quotient, nil, numerator, denominator);
}
internal_div :: proc { internal_int_div, };

/*
	remainder = numerator % denominator.
	0 <= remainder < denominator if denominator > 0
	denominator < remainder <= 0 if denominator < 0

	Asssumes quotient, numerator and denominator to have been initialized and not to be nil.
*/
internal_int_mod :: proc(remainder, numerator, denominator: ^Int) -> (err: Error) {
	if err = #force_inline internal_int_divmod(nil, remainder, numerator, denominator); err != nil { return err; }

	if remainder.used == 0 || denominator.sign == remainder.sign { return nil; }

	return #force_inline internal_add(remainder, remainder, numerator);
}
internal_mod :: proc{ internal_int_mod, };

/*
	remainder = (number + addend) % modulus.
*/
internal_int_addmod :: proc(remainder, number, addend, modulus: ^Int) -> (err: Error) {
	if err = #force_inline internal_add(remainder, number, addend); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus);
}
internal_addmod :: proc { internal_int_addmod, };

/*
	remainder = (number - decrease) % modulus.
*/
internal_int_submod :: proc(remainder, number, decrease, modulus: ^Int) -> (err: Error) {
	if err = #force_inline internal_sub(remainder, number, decrease); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus);
}
internal_submod :: proc { internal_int_submod, };

/*
	remainder = (number * multiplicand) % modulus.
*/
internal_int_mulmod :: proc(remainder, number, multiplicand, modulus: ^Int) -> (err: Error) {
	if err = #force_inline internal_mul(remainder, number, multiplicand); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus);
}
internal_mulmod :: proc { internal_int_mulmod, };

/*
	remainder = (number * number) % modulus.
*/
internal_int_sqrmod :: proc(remainder, number, modulus: ^Int) -> (err: Error) {
	if err = #force_inline internal_mul(remainder, number, number); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus);
}
internal_sqrmod :: proc { internal_int_sqrmod, };



/*
	TODO: Use Sterling's Approximation to estimate log2(N!) to size the result.
	This way we'll have to reallocate less, possibly not at all.
*/
internal_int_factorial :: proc(res: ^Int, n: int) -> (err: Error) {
	if n >= _FACTORIAL_BINARY_SPLIT_CUTOFF {
		return #force_inline _int_factorial_binary_split(res, n);
	}

	i := len(_factorial_table);
	if n < i {
		return #force_inline set(res, _factorial_table[n]);
	}

	if err = #force_inline set(res, _factorial_table[i - 1]); err != nil { return err; }
	for {
		if err = #force_inline internal_mul(res, res, DIGIT(i)); err != nil || i == n { return err; }
		i += 1;
	}

	return nil;
}

_int_recursive_product :: proc(res: ^Int, start, stop: int, level := int(0)) -> (err: Error) {
	t1, t2 := &Int{}, &Int{};
	defer destroy(t1, t2);

	if level > _FACTORIAL_BINARY_SPLIT_MAX_RECURSIONS { return .Max_Iterations_Reached; }

	num_factors := (stop - start) >> 1;
	if num_factors == 2 {
		if err = set(t1, start); err != nil { return err; }
		when true {
			if err = grow(t2, t1.used + 1); err != nil { return err; }
			if err = internal_add(t2, t1, 2); err != nil { return err; }
		} else {
			if err = add(t2, t1, 2); err != nil { return err; }
		}
		return internal_mul(res, t1, t2);
	}

	if num_factors > 1 {
		mid := (start + num_factors) | 1;
		if err = _int_recursive_product(t1, start,  mid, level + 1); err != nil { return err; }
		if err = _int_recursive_product(t2,   mid, stop, level + 1); err != nil { return err; }
		return internal_mul(res, t1, t2);
	}

	if num_factors == 1 { return #force_inline set(res, start); }

	return #force_inline set(res, 1);
}

/*
	Binary split factorial algo due to: http://www.luschny.de/math/factorial/binarysplitfact.html
*/
_int_factorial_binary_split :: proc(res: ^Int, n: int) -> (err: Error) {

	inner, outer, start, stop, temp := &Int{}, &Int{}, &Int{}, &Int{}, &Int{};
	defer destroy(inner, outer, start, stop, temp);

	if err = set(inner, 1); err != nil { return err; }
	if err = set(outer, 1); err != nil { return err; }

	bits_used := int(_DIGIT_TYPE_BITS - intrinsics.count_leading_zeros(n));

	for i := bits_used; i >= 0; i -= 1 {
		start := (n >> (uint(i) + 1)) + 1 | 1;
		stop  := (n >> uint(i)) + 1 | 1;
		if err = _int_recursive_product(temp, start, stop); err != nil { return err; }
		if err = internal_mul(inner, inner, temp);                   err != nil { return err; }
		if err = internal_mul(outer, outer, inner);                  err != nil { return err; }
	}
	shift := n - intrinsics.count_ones(n);

	return shl(res, outer, int(shift));
}



internal_int_zero_unused :: #force_inline proc(dest: ^Int, old_used := -1) {
	/*
		If we don't pass the number of previously used DIGITs, we zero all remaining ones.
	*/
	zero_count: int;
	if old_used == -1 {
		zero_count = len(dest.digit) - dest.used;
	} else {
		zero_count = old_used - dest.used;
	}

	/*
		Zero remainder.
	*/
	if zero_count > 0 && dest.used < len(dest.digit) {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
}

internal_zero_unused :: proc { internal_int_zero_unused, };

/*
	Tables.
*/

when MATH_BIG_FORCE_64_BIT || (!MATH_BIG_FORCE_32_BIT && size_of(rawptr) == 8) {
	_factorial_table := [35]_WORD{
/* f(00): */                                                   1,
/* f(01): */                                                   1,
/* f(02): */                                                   2,
/* f(03): */                                                   6,
/* f(04): */                                                  24,
/* f(05): */                                                 120,
/* f(06): */                                                 720,
/* f(07): */                                               5_040,
/* f(08): */                                              40_320,
/* f(09): */                                             362_880,
/* f(10): */                                           3_628_800,
/* f(11): */                                          39_916_800,
/* f(12): */                                         479_001_600,
/* f(13): */                                       6_227_020_800,
/* f(14): */                                      87_178_291_200,
/* f(15): */                                   1_307_674_368_000,
/* f(16): */                                  20_922_789_888_000,
/* f(17): */                                 355_687_428_096_000,
/* f(18): */                               6_402_373_705_728_000,
/* f(19): */                             121_645_100_408_832_000,
/* f(20): */                           2_432_902_008_176_640_000,
/* f(21): */                          51_090_942_171_709_440_000,
/* f(22): */                       1_124_000_727_777_607_680_000,
/* f(23): */                      25_852_016_738_884_976_640_000,
/* f(24): */                     620_448_401_733_239_439_360_000,
/* f(25): */                  15_511_210_043_330_985_984_000_000,
/* f(26): */                 403_291_461_126_605_635_584_000_000,
/* f(27): */              10_888_869_450_418_352_160_768_000_000,
/* f(28): */             304_888_344_611_713_860_501_504_000_000,
/* f(29): */           8_841_761_993_739_701_954_543_616_000_000,
/* f(30): */         265_252_859_812_191_058_636_308_480_000_000,
/* f(31): */       8_222_838_654_177_922_817_725_562_880_000_000,
/* f(32): */     263_130_836_933_693_530_167_218_012_160_000_000,
/* f(33): */   8_683_317_618_811_886_495_518_194_401_280_000_000,
/* f(34): */ 295_232_799_039_604_140_847_618_609_643_520_000_000,
	};
} else {
	_factorial_table := [21]_WORD{
/* f(00): */                                                   1,
/* f(01): */                                                   1,
/* f(02): */                                                   2,
/* f(03): */                                                   6,
/* f(04): */                                                  24,
/* f(05): */                                                 120,
/* f(06): */                                                 720,
/* f(07): */                                               5_040,
/* f(08): */                                              40_320,
/* f(09): */                                             362_880,
/* f(10): */                                           3_628_800,
/* f(11): */                                          39_916_800,
/* f(12): */                                         479_001_600,
/* f(13): */                                       6_227_020_800,
/* f(14): */                                      87_178_291_200,
/* f(15): */                                   1_307_674_368_000,
/* f(16): */                                  20_922_789_888_000,
/* f(17): */                                 355_687_428_096_000,
/* f(18): */                               6_402_373_705_728_000,
/* f(19): */                             121_645_100_408_832_000,
/* f(20): */                           2_432_902_008_176_640_000,
	};
};