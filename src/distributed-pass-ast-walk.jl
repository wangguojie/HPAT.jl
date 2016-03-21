#=
Copyright (c) 2016, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without 
modification, are permitted provided that the following conditions are met:
- Redistributions of source code must retain the above copyright notice, 
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, 
  this list of conditions and the following disclaimer in the documentation 
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF 
THE POSSIBILITY OF SUCH DAMAGE.
=#


function getArrayDistributionInfo(ast, state)
    before_dist_arrays = [arr for arr in keys(state.arrs_dist_info)]
    
    while true
        dist_arrays = []
        @dprintln(3,"DistPass state before array info walk: ",state)
        AstWalk(ast, get_arr_dist_info, state)
        @dprintln(3,"DistPass state after array info walk: ",state)
            # all arrays not marked sequential are distributable at this point 
        for arr in keys(state.arrs_dist_info)
            if state.arrs_dist_info[arr].isSequential==false
                @dprintln(2,"DistPass distributable parfor array: ", arr)
                push!(dist_arrays,arr)
            end
        end
        # break if no new sequential array discovered
        if length(dist_arrays)==length(before_dist_arrays)
            break
        end
        before_dist_arrays = dist_arrays
    end
    state.dist_arrays = before_dist_arrays
    @dprintln(3,"DistPass state dist_arrays after array info walk: ",state.dist_arrays)
end

"""
mark sequential arrays
"""
function get_arr_dist_info(node::Expr, state::DistPassState, top_level_number, is_top_level, read)
    head = node.head
    # arrays written in parfors are ok for now
    
    @dprintln(3,"DistPass arr info walk Expr head: ", head)
    if head==:(=)
        @dprintln(3,"DistPass arr info walk assignment: ", node)
        lhs = toSymGen(node.args[1])
        rhs = node.args[2]
        return get_arr_dist_info_assignment(node, state, top_level_number, lhs, rhs)
    elseif head==:parfor
        @dprintln(3,"DistPass arr info walk parfor: ", node)
        parfor = getParforNode(node)
        rws = parfor.rws
        
        readArrs = collect(keys(rws.readSet.arrays))
        writeArrs = collect(keys(rws.writeSet.arrays))
        allArrs = [readArrs;writeArrs]
        # keep mapping from parfors to arrays
        state.parfor_info[parfor.unique_id] = allArrs
        seq = false
        
        if length(parfor.arrays_read_past_index)!=0 || length(parfor.arrays_written_past_index)!=0 
            @dprintln(2,"DistPass arr info walk parfor sequential: ", node)
            for arr in allArrs
                seq = true
            end
        end
        
        indexVariable::SymbolNode = parfor.loopNests[1].indexVariable
        for arr in keys(rws.readSet.arrays)
             index = rws.readSet.arrays[arr]
             if length(index)!=1 || toSymGen(index[1][end])!=toSymGen(indexVariable)
                @dprintln(2,"DistPass arr info walk arr read index sequential: ", index, " ", indexVariable)
                seq = true
             end
        end
        
        for arr in keys(rws.writeSet.arrays)
             index = rws.writeSet.arrays[arr]
             if length(index)!=1 || toSymGen(index[1][end])!=toSymGen(indexVariable)
                @dprintln(2,"DistPass arr info walk arr write index sequential: ", index, " ", indexVariable)
                seq = true
             end
        end
        for arr in allArrs
            if state.arrs_dist_info[arr].isSequential ||
                        !isEqualDimSize(state.arrs_dist_info[arr].dim_sizes, state.arrs_dist_info[allArrs[1]].dim_sizes)
                    @dprintln(2,"DistPass parfor check array: ", arr," seq: ", state.arrs_dist_info[arr].isSequential)
                    seq = true
            end
        end
        # parfor and all its arrays are sequential
        if seq
            push!(state.seq_parfors, parfor.unique_id)
            for arr in allArrs
                state.arrs_dist_info[arr].isSequential = true
            end
        end
        return node
    # functions dist_ir_funcs are either handled here or do not make arrays sequential  
    elseif head==:call && in(node.args[1], dist_ir_funcs)
        func = node.args[1]
        if func==:__hpat_data_source_HDF5_read || func==:__hpat_data_source_TXT_read
            @dprintln(2,"DistPass arr info walk data source read ", node)
            # will be parallel IO, intentionally do nothing
        elseif func==:__hpat_Kmeans
            @dprintln(2,"DistPass arr info walk kmeans ", node)
            # first array is cluster output and is sequential
            # second array is input matrix and is parallel
            state.arrs_dist_info[toSymGen(node.args[2])].isSequential = true
        elseif func==:__hpat_LinearRegression || func==:__hpat_NaiveBayes
            @dprintln(2,"DistPass arr info walk LinearRegression/NaiveBayes ", node)
            # first array is cluster output and is sequential
            # second array is input matrix and is parallel
            # third array is responses and is parallel
            state.arrs_dist_info[toSymGen(node.args[2])].isSequential = true
        end
        return node
    # arrays written in sequential code are not distributed
    elseif head!=:body && head!=:block && head!=:lambda
        @dprintln(3,"DistPass arr info walk sequential code: ", node)
        live_info = CompilerTools.LivenessAnalysis.find_top_number(top_level_number, state.lives)
        
        all_vars = union(live_info.def, live_info.use)
        
        # ReadWriteSet is not robust enough now
        #rws = CompilerTools.ReadWriteSet.from_exprs([node], ParallelIR.pir_live_cb, state.LambdaVarInfo)
        #readArrs = collect(keys(rws.readSet.arrays))
        #writeArrs = collect(keys(rws.writeSet.arrays))
        #allArrs = [readArrs;writeArrs]
        
        for var in all_vars
            if haskey(state.arrs_dist_info, toSymGen(var))
                @dprintln(2,"DistPass arr info walk array in sequential code: ", var, " ", node)
                
                state.arrs_dist_info[toSymGen(var)].isSequential = true
            end
        end
        return node
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end


function get_arr_dist_info(ast::Any, state::DistPassState, top_level_number, is_top_level, read)
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end


function get_arr_dist_info_assignment(node::Expr, state::DistPassState, top_level_number, lhs, rhs)
    if isAllocation(rhs)
            state.arrs_dist_info[lhs].dim_sizes = map(toSynGemOrInt, get_alloc_shape(rhs.args[2:end]))
            @dprintln(3,"DistPass arr info dim_sizes update: ", state.arrs_dist_info[lhs].dim_sizes)
    elseif isa(rhs,SymAllGen)
        rhs = toSymGen(rhs)
        if haskey(state.arrs_dist_info, rhs)
            state.arrs_dist_info[lhs].dim_sizes = state.arrs_dist_info[rhs].dim_sizes
            # lhs and rhs are sequential if either is sequential
            seq = state.arrs_dist_info[lhs].isSequential || state.arrs_dist_info[rhs].isSequential
            state.arrs_dist_info[lhs].isSequential = state.arrs_dist_info[rhs].isSequential = seq
            @dprintln(3,"DistPass arr info dim_sizes update: ", state.arrs_dist_info[lhs].dim_sizes)
        end
    elseif isa(rhs,Expr) && rhs.head==:call && in(rhs.args[1], dist_ir_funcs)
        func = rhs.args[1]
        if func==GlobalRef(Base,:reshape)
            # only reshape() with constant tuples handled
            if haskey(state.tuple_table, rhs.args[3])
                state.arrs_dist_info[lhs].dim_sizes = state.tuple_table[rhs.args[3]]
                @dprintln(3,"DistPass arr info dim_sizes update: ", state.arrs_dist_info[lhs].dim_sizes)
                # lhs and rhs are sequential if either is sequential
                seq = state.arrs_dist_info[lhs].isSequential || state.arrs_dist_info[toSymGen(rhs.args[2])].isSequential
                state.arrs_dist_info[lhs].isSequential = state.arrs_dist_info[toSymGen(rhs.args[2])].isSequential = seq
            else
                @dprintln(3,"DistPass arr info reshape tuple not found: ", rhs.args[3])
                state.arrs_dist_info[lhs].isSequential = state.arrs_dist_info[toSymGen(rhs.args[2])].isSequential = true
            end
        elseif rhs.args[1]==TopNode(:tuple)
            ok = true
            for s in rhs.args[2:end]
                if !(isa(s,SymbolNode) || isa(s,Int))
                    ok = false
                end 
            end 
            if ok
                state.tuple_table[lhs] = [  toSymGenOrNum(s) for s in rhs.args[2:end] ]
                @dprintln(3,"DistPass arr info tuple constant: ", lhs," ",rhs.args[2:end])
            else
                @dprintln(3,"DistPass arr info tuple not constant: ", lhs," ",rhs.args[2:end])
            end 
        elseif func==GlobalRef(Base.LinAlg,:gemm_wrapper!)
            # determine output dimensions
            state.arrs_dist_info[lhs].dim_sizes = state.arrs_dist_info[toSymGen(rhs.args[2])].dim_sizes
            arr1 = toSymGen(rhs.args[5])
            t1 = (rhs.args[3]=='T')
            arr2 = toSymGen(rhs.args[6])
            t2 = (rhs.args[4]=='T')
            
            seq = false
            
            # result is sequential if both inputs are sequential 
            if state.arrs_dist_info[arr1].isSequential && state.arrs_dist_info[arr2].isSequential
                seq = true
            # result is sequential but with reduction if both inputs are partitioned and second one is transposed
            # e.g. labels*points'
            elseif !state.arrs_dist_info[arr1].isSequential && !state.arrs_dist_info[arr2].isSequential && t2 && !t1
                seq = true
            # first input is sequential but output is parallel if the second input is partitioned but not transposed
            # e.g. w*points
            elseif !state.arrs_dist_info[arr2].isSequential && !t2
                @dprintln(3,"DistPass arr info gemm first input is sequential: ", arr1)
                state.arrs_dist_info[arr1].isSequential = true
            # otherwise, no known pattern found, every array is sequential
            else
                @dprintln(3,"DistPass arr info gemm all sequential: ", arr1," ", arr2)
                state.arrs_dist_info[arr1].isSequential = true
                state.arrs_dist_info[arr2].isSequential = true
                seq = true
            end
            
            if seq
                @dprintln(3,"DistPass arr info gemm output is sequential: ", lhs," ",rhs.args[2])
            end
            state.arrs_dist_info[lhs].isSequential = state.arrs_dist_info[toSymGen(rhs.args[2])].isSequential = seq
        end
    else
        return CompilerTools.AstWalker.ASTWALK_RECURSE
    end
    return node
end


function isEqualDimSize(sizes1::Array{Union{SymAllGen,Int,Expr},1} , sizes2::Array{Union{SymAllGen,Int,Expr},1})
    if length(sizes1)!=length(sizes2)
        return false
    end
    for i in 1:length(sizes1)
        if !eqSize(sizes1[i],sizes2[i])
            return false
        end
    end
    return true
end

function eqSize(a::Expr, b::Expr)
    if a.head!=b.head || length(a.args)!=length(b.args)
        return false
    end
    for i in 1:length(a.args)
        if !eqSize(a.args[i],b.args[i])
            return false
        end
    end
    return true 
end

function eqSize(a::SymbolNode, b::SymbolNode)
    return a.name == b.name
end

function eqSize(a::Any, b::Any)
    return a==b
end
