# Copyright (C) 2010, Nathaniel J. Smith <njs@pobox.com>
# This code released under a 2-clause BSD license, see COPYING.
# SRILM itself is under an ad hoc "non-free" license though.

# See:
#   http://wiki.cython.org/WrappingCPlusPlus
# for discussion of the crazy hacks we use to trick pyrex into generating
# valid c++.
#
# These shouldn't be necessary anymore, since Cython has learned a bunch about
# C++ since. But this is old code...

# compile me with cython --cplus, or Extension(..., language="c++", ...)

cdef extern from "unistd.h":
    void * malloc(int)
    void free(void *)

cdef extern from *:
    ctypedef int Boolean # not sure if this is right...

cdef extern from "File.h":
    ctypedef struct c_File "File":
        pass
    c_File * new_File "new File" (char * path, char * mode) except +
    void del_File "delete" (c_File *)

cdef extern from "Vocab.h":
    ctypedef int VocabIndex
    ctypedef char * VocabString
    VocabIndex Vocab_None
    ctypedef struct c_Vocab "Vocab":
        # These two actually return Boolean&'s, but if we just ignore that
        # then things work out okay...
        Boolean (*unkIsWord)()
        Boolean (*toLower)()
        VocabString (*getWord)(VocabIndex)
        VocabIndex (*getIndex)(VocabString, VocabIndex unkIndex)
        VocabIndex (*unkIndex)()
        VocabIndex (*ssIndex)()
        VocabIndex (*seIndex)()
        VocabIndex (*highIndex)()
        Boolean (*isNonEvent)(VocabIndex word)
    c_Vocab * new_Vocab "new Vocab" ()
    void del_Vocab "delete" (c_Vocab *)

cdef extern from "Ngram.h":
    ctypedef double LogP
    ctypedef struct c_Ngram "Ngram":
        void (*read)(c_File)
        LogP (*wordProb)(VocabIndex word, VocabIndex * context)
        Boolean debugme(int)
        
    c_Ngram * new_Ngram "new Ngram" (c_Vocab, int)
    void del_Ngram "delete" (c_Ngram *)

cdef extern from "srilm-c++-hacks.hh":
    Boolean * take_address_of_bool "take_address_of<Boolean>"(Boolean b)

###########################################################################

cdef class _Vocab:
    cdef c_Vocab * _vocab
    def __cinit__(self, lower):
        self._vocab = new_Vocab()
        take_address_of_bool(self._vocab.unkIsWord())[0] = 1
        take_address_of_bool(self._vocab.toLower())[0] = bool(lower)

    def __dealloc__(self):
        del_Vocab(self._vocab)

    def intern(self, word):
        return self._vocab.getIndex(word,
                                    self._vocab.unkIndex())

    def extern(self, idx):
        cdef VocabString s
        s = self._vocab.getWord(idx)
        if s:
            return s
        else:
            return None

    # to iterate over all words, use range(max_interned() + 1) and be prepared
    # for extern to return None
    def max_interned(self):
        return self._vocab.highIndex()

    # Returns True for weirdo entities like <unk>, <s>, etc.
    # Vocab defines a isNonEvent() call but it doesn't really work right...
    def is_non_word(self, idx):
        cdef VocabIndex c_idx = idx
        return (c_idx == self._vocab.unkIndex()
                or c_idx == self._vocab.ssIndex()
                or c_idx == self._vocab.seIndex()
                or self._vocab.isNonEvent(c_idx))

cdef class LM:
    cdef public _Vocab vocab
    cdef c_Ngram * _ngram
    cdef public object path
    def __cinit__(self, path, debug=False, lower=False, vocab=None):
        if vocab is None:
            vocab = _Vocab(lower)
        self.vocab = vocab
        self._ngram = new_Ngram(self.vocab._vocab[0], 20)
        if debug:
            self._ngram.debugme(10)
        cdef c_File * fp
        fp = new_File(path, "r")
        self._ngram.read(fp[0])
        del_File(fp)
        self.path = path

    def __dealloc__(self):
        del_Ngram(self._ngram)

    # Usage: log P(brown | the quick)
    #     -> logprob_strings("brown", ["quick", "the"])
    def logprob_strings(self, word, context):
        word_i = self.vocab.intern(word)
        context_i = map(self.vocab.intern, context)
        return self.logprob(word_i, context_i)
        
    # Like above, but takes interned words.
    # Note that this may return -inf
    def logprob(self, word, context):
        cdef VocabIndex c_context[20]
        cdef int i, length = len(context)
        if length >= 20:
            length = 19
        for 0 <= i < length:
            c_context[i] = context[i]
        c_context[length] = Vocab_None
        return self._ngram.wordProb(word, c_context)

    # Takes a list like ["The", "man", "who"], and returns the total
    # log-probability of a sentence starting with that:
    #   logP(The | <s>) + logP(man | <s> The) + logP(who | <s> The man)
    def total_logprob_strings(self, ngram):
        ngram_i = map(self.vocab.intern, ngram)
        ngram_i.reverse()
        ngram_i.append(self.vocab.intern("<s>"))
        lp = 0
        for 0 <= i < len(ngram_i) - 1:
            lp = lp + self.logprob(ngram_i[i], ngram_i[i + 1:])
        return lp

    # FIXME: add a wrapper for Ngram::contextID(), whose &length argument
    # returns the order of the ngram that was actually used (so we can query
    # about backoff)
