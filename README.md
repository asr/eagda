Extended version of Agda
========================

[![Build Status](https://travis-ci.org/asr/eagda.svg?branch=master)](https://travis-ci.org/asr/eagda)

Description
-----------

We have extended the development version of Agda in order to handle a
new built-in ATP-pragma.

This version of Agda is used for reasoning about functional programs
by combining interactive and automatic proofs (see
[README.md](https://github.com/asr/fotc/blob/master/README.md)).

Installation
------------

You can download our extended version of Agda using
[Git](http://git-scm.com/) with the following command:

```bash
$ git clone https://github.com/asr/eagda.git
```

This will create a directory called `eagda`. Installing our extended
version is similar to the installation of Agda (see
[README.md](https://github.com/agda/agda/blob/master/README.md) for
more information). In our setup, we run the first time the following
commands:

```bash
$ cd eagda
$ make install-bin
$ agda-mode setup
```

To test the installation of the extended version of Agda, type-check a
module which uses the new built-in ATP-pragma, for example

```agda
module Test where

data _∨_ (A B : Set) : Set where
  inj₁ : A → A ∨ B
  inj₂ : B → A ∨ B

postulate
  A B    : Set
  ∨-comm : A ∨ B → B ∨ A
{-# ATP prove ∨-comm #-}
```
