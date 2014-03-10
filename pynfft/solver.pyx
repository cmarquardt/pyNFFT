# -*- coding: utf-8 -*-
#
# Copyright (C) 2013-2014  Ghislain Vaillant
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

import copy
import numpy as np
cimport numpy as np
from libc.stdlib cimport malloc, free
from cnfft3 cimport *
from .nfft cimport NFFT
from .nfft import NFFT


solver_flags_dict = {
    'LANDWEBER':LANDWEBER,
    'STEEPEST_DESCENT':STEEPEST_DESCENT,
    'CGNR':CGNR,
    'CGNE':CGNE,
    'NORMS_FOR_LANDWEBER':NORMS_FOR_LANDWEBER,
    'PRECOMPUTE_WEIGHT':PRECOMPUTE_WEIGHT,
    'PRECOMPUTE_DAMP':PRECOMPUTE_DAMP,
    }

solver_flags = copy.copy(solver_flags_dict)


cdef class Solver(object):
    '''
    Solver is a class for computing the adjoint NFFT iteratively..

    The instantiation requires a NFFT object used internally for the multiple
    forward and adjoint NFFT performed. The class uses conjugate-gradient as
    the default solver but alternative solvers can be specified.

    Because the stopping conidition of the iterative computation may change
    from one application to another, the implementation only let you carry
    one iteration at a time with a call to :meth:`loop_one_step`. 
    Initialization of the solver is done by calling the :meth:`before_loop` 
    method.

    The class exposes the internals of the solver through call to their
    respective properties.
    '''

    def __cinit__(self, NFFT nfft_plan, flags=None):

        # support only double / double complex NFFT
        # TODO: if support for multiple floating precision lands in the
        # NFFT library, adapt this section to dynamically figure the
        # real and complex dtypes
        dtype_real = np.dtype('float64')
        dtype_complex = np.dtype('complex128')

        # convert tuple of litteral precomputation flags to its expected
        # C-compatible value. Each flag is a power of 2, which allows to compute
        # this value using BITOR operations.
        cdef unsigned int _flags = 0
        flags_used = ()

        # sanity checks on user specified flags if any,
        # else use default ones:
        if flags is not None:
            try:
                flags = tuple(flags)
            except:
                flags = (flags,)
            finally:
                flags_used += flags
        else:
            flags_used += ('CGNR',)

        for each_flag in flags_used:
            try:
                _flags |= solver_flags_dict[each_flag]
            except KeyError:
                raise ValueError('Invalid flag: ' + '\'' +
                        each_flag + '\' is not a valid flag.')

        # initialize plan
        try:
            solver_init_advanced_complex(&self._solver_plan,
                <nfft_mv_plan_complex*>&(nfft_plan._plan), _flags)
        except:
            raise MemoryError

        self._nfft_plan = nfft_plan
        d = nfft_plan.d
        M = nfft_plan.M
        N = nfft_plan.N

        cdef np.npy_intp shape_M[1]
        shape_M[0] = M

        self._r_iter = np.PyArray_SimpleNewFromData(1, shape_M,
            np.NPY_COMPLEX128, <void *>(self._solver_plan.r_iter))

        self._y = np.PyArray_SimpleNewFromData(1, shape_M,
            np.NPY_COMPLEX128, <void *>(self._solver_plan.y))

        if 'PRECOMPUTE_WEIGHT' in flags_used:
            self._w = np.PyArray_SimpleNewFromData(1, shape_M,
                np.NPY_FLOAT64, <void *>(self._solver_plan.w))
            self._w[:] = 1  # make sure weights are initialized
        else:
            self._w = None

        cdef np.npy_intp *shape_N
        try:
            shape_N = <np.npy_intp*>malloc(d*sizeof(np.npy_intp))
        except:
            raise MemoryError
        for dt in range(d):
            shape_N[dt] = N[dt]

        self._f_hat_iter = np.PyArray_SimpleNewFromData(d, shape_N,
            np.NPY_COMPLEX128, <void *>(self._solver_plan.f_hat_iter))
        self._f_hat_iter[:] = 0  # default initial guess

        if 'PRECOMPUTE_DAMP' in flags_used:
            self._w_hat = np.PyArray_SimpleNewFromData(d, shape_N,
                np.NPY_FLOAT64, <void *>(self._solver_plan.w_hat))
            self._w_hat[:] = 1  # make sure weights are initialized
        else:
            self._w_hat = None

        free(shape_N)

        self._dtype = dtype_complex
        self._flags = flags_used


    def __init__(self, nfft_plan, flags=None):
        '''
        :param plan: instance of NFFT.
        :type plan: :class:`NFFT`
        :param flags: list of instantiation flags, see below.
        :type flags: tuple

        **Instantiation flags**

        +---------------------+-----------------------------------------------------------------------------+
        | Flag                | Description                                                                 |
        +=====================+=============================================================================+
        | LANDWEBER           | Use Landweber (Richardson) iteration.                                       |
        +---------------------+-----------------------------------------------------------------------------+
        | STEEPEST_DESCENT    | Use steepest descent iteration.                                             |
        +---------------------+-----------------------------------------------------------------------------+
        | CGNR                | Use conjugate gradient (normal equation of the 1st kind).                   |
        +---------------------+-----------------------------------------------------------------------------+
        | CGNE                | Use conjugate gradient (normal equation of the 2nd kind).                   |
        +---------------------+-----------------------------------------------------------------------------+
        | NORMS_FOR_LANDWEBER | Use Landweber iteration to compute the residual norm.                       |
        +---------------------+-----------------------------------------------------------------------------+
        | PRECOMPUTE_WEIGHT   | Weight the samples, e.g. to cope with varying sampling density.             |
        +---------------------+-----------------------------------------------------------------------------+
        | PRECOMPUTE_DAMP     | Weight the Fourier coefficients, e.g. to favour fast decaying coefficients. |
        +---------------------+-----------------------------------------------------------------------------+

        Default value is ``flags = ('CGNR',)``.
        '''
        pass

    def __dealloc__(self):
        solver_finalize_complex(&self._solver_plan)

    def before_loop(self):
        '''Initialize the solver internals.'''
        self.solver_before_loop()

    def loop_one_step(self):
        '''Perform one iteration of the solver.'''
        self.solver_loop_one_step()

    cdef void solver_before_loop(self):
        with nogil:
            solver_before_loop_complex(&self._solver_plan)

    cdef void solver_loop_one_step(self):
        with nogil:
            solver_loop_one_step_complex(&self._solver_plan)

    @property
    def w(self):
        '''Weighting factors.'''
        return self._w

    @property
    def w_hat(self):
        '''Damping factors.'''
        return self._w_hat

    @property
    def y(self):
        '''Right hand side, samples.'''
        return self._y

    @property
    def f_hat_iter(self):
        '''Iterative solution.'''
        return self._f_hat_iter

    @property
    def r_iter(self):
        '''Residual vector.'''
        return self._r_iter

    @property
    def dtype(self):
        '''The dtype of the solver.'''
        return self._dtype

    @property
    def flags(self):
        '''The precomputation flags.'''
        return self._flags
