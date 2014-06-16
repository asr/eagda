# Description

  We have modified the development version of Agda in order to handle
  a new built-in ATP-pragma.

# Use

  * Reasoning about Functional Programs by Combining Interactive and
    Automatic Proofs
    ([README.md](https://github.com/asr/fotc/blob/master/README.md)).

# Installation

   You can download our modified version of Agda using
   [Git](http://git-scm.com/) with the following command:

   ````bash
   $ git clone https://github.com/asr/magda.git
   ````

   This will create a directory called `magda`. Installing our
   modified version is similar to the installation of Agda (see
   [README.md](https://github.com/agda/agda/blob/master/README.md) for
   more information). In our setup, we run the first time the following
   commands:

   ````bash
   $ cd magda
   $ autoconf
   $ ./configure
   $ make install-bin
   $ agda-mode setup
   ````

   To test the installation of the modified version of Agda, type-check
   a module which uses the new built-in ATP-pragma, for example

   ````Agda
   module Test where

   data _∨_ (A B : Set) : Set where
     inj₁ : A → A ∨ B
     inj₂ : B → A ∨ B

   postulate
     A B    : Set
     ∨-comm : A ∨ B → B ∨ A
   {-# ATP prove ∨-comm #-}
   ````

# Agda version

   In order to avoid conflicts with other installed versions of Agda,
   we have added extra information to the version number of Agda,
   i.e. if the development version number of Agda is A.B.C, our
   modified version number is A.B.C.1.
