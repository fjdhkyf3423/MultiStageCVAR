include("src/MultiStageCVAR.jl")
using CPLEX
using PowerSimulations
using PowerSystems
using Dates
using CSV
using DataFrames
using Random
Random.seed!(5516)
#using PlotlyJS

solver = JuMP.optimizer_with_attributes(
    CPLEX.Optimizer,
    "CPXPARAM_MIP_Tolerances_MIPGap" => 1e-2,
    "CPXPARAM_Emphasis_MIP" => 1,
)

initial_time = DateTime("2018-04-01T00:00:00")
system_ha = initialize_system("data/HA_sys.json", solver, initial_time)
 system_da = initialize_system("data/DA_sys.json", solver, initial_time)
# system_ed = System("data/RT_sys.json"; time_series_read_only = true)

sddp_solver =
    JuMP.optimizer_with_attributes(CPLEX.Optimizer, "CPXPARAM_Emphasis_Numerical" => 1)

PSY.configure_logging(file_level = Logging.Error, console_level = Logging.Info)

template_hauc = OperationsProblemTemplate(CopperPlatePowerModel)
template_dauc = OperationsProblemTemplate(CopperPlatePowerModel)

for template in [template_dauc, template_hauc]
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, HydroDispatch, FixedOutput)
    set_device_model!(template, ThermalMultiStart, ThermalStandardUnitCommitment)
    set_service_model!(template, ServiceModel(VariableReserve{ReserveUp}, RampReserve))
    set_service_model!(template, ServiceModel(VariableReserve{ReserveDown}, RampReserve))
end

set_device_model!(template_hauc, ThermalMultiStart, ThermalBasicUnitCommitment)

DAUC = OperationsProblem(
    StandardDAUnitCommitmentCC,
    template_dauc,
    system_da,
    optimizer = solver,
    optimizer_log_print = true,
    initial_time = initial_time,
)

DAUC.ext["cc_restrictions"] = JSON.parsefile("data/cc_restrictions.json")

build!(DAUC; output_dir = mktempdir(), serialize = false)
solve!(DAUC)
results = ProblemResults(DAUC)

reg_up = results.variable_values[:REG_UP__VariableReserve_ReserveUp]
# reg_up = CSV.read("data/reg_up.csv", DataFrame)
CSV.write("data/reg_up.csv", reg_up)
reg_dn = results.variable_values[:REG_DN__VariableReserve_ReserveDown]
#reg_dn = CSV.read("data/reg_dn.csv", DataFrame)
CSV.write("data/reg_dn.csv", reg_dn)
spin = results.variable_values[:SPIN__VariableReserve_ReserveUp]
#spin = CSV.read("data/reg_spin.csv", DataFrame)
CSV.write("data/reg_spin.csv", spin)

t = [sum(r[2:end]) for r in eachrow(reg_dn)]

t = [sum(r[2:end]) for r in eachrow(reg_up)]
#=
traces = Vector{GenericTrace{Dict{Symbol, Any}}}()
for i in eachcol(reg_up)
    if eltype(i) == Float64 && sum(i) > 1e-3
        push!(traces, PlotlyJS.scatter(y = i))
    end
end

plot(traces, Layout())

reg = results.variable_values[:SPIN__VariableReserve_ReserveUp]
traces = Vector{GenericTrace{Dict{Symbol, Any}}}()
for i in eachcol(reg)
    if eltype(i) == Float64 && sum(i) > 1e-3
        push!(traces, PlotlyJS.scatter(y = i))
    end
end

plot(traces, Layout())
=#

HAUC = OperationsProblem(
    StandardHAUnitCommitmentCC,
    template_hauc,
    system_ha,
    optimizer = solver,
    optimizer_log_print = false,
    services_slack_variables = false,
)

HAUC.ext["cc_restrictions"] = JSON.parsefile("data/cc_restrictions.json")
HAUC.ext["resv_dauc"] = Dict(:reg_up_da => reg_up, :reg_dn_da => reg_dn, :spin_da => spin)

RCVAR = OperationsProblem(MultiStageCVAR, template_hauc, system_ha, optimizer = sddp_solver)
RCVAR.ext["resv_dauc"] = Dict(:reg_up_da => reg_up, :reg_dn_da => reg_dn, :spin_da => spin)
RCVAR.ext["ϵ"] = 0.2
RCVAR.ext["time_limit"] = 3600

problems = SimulationProblems(
    #DAUC = DAUC,
    HAUC = HAUC,
    MSCVAR = RCVAR,
    #ED = ED,
)

sequence = SimulationSequence(
    problems = problems,
    #feedforward_chronologies = Dict(("DAUC" => "HAUC") => Synchronize(periods = 24)),
    intervals = Dict(
        #"DAUC" => (Hour(24), Consecutive()),
        "HAUC" => (Hour(1), RecedingHorizon()),
        "MSCVAR" => (Hour(1), RecedingHorizon()),
        #"ED" => (Minute(5), RecedingHorizon()),
    ),
    #feedforward = Dict(
    #    ("ED", :devices, :ThermalMultiStart) => SemiContinuousFF(
    #        binary_source_problem = PSI.ON,
    #        affected_variables = [PSI.ACTIVE_POWER],
    #    ),
    #),
    #ini_cond_chronology = InterProblemChronology(),
    ini_cond_chronology = IntraProblemChronology(),
)


sim = Simulation(
    name = "standard",
    steps = 24,
    problems = problems,
    sequence = sequence,
    initial_time = initial_time,
    simulation_folder = "results",
)

build_out =
    build!(sim; console_level = Logging.Info, file_level = Logging.Warn, serialize = false)
execute_out = execute!(sim)

#=
results_sim = SimulationResults("results/standard_july/", 1; ignore_status = true)
op_problem_res = get_problem_results(results_sim, "HAUC")
reg_dn_sim = read_variable(op_problem_res, :REG_UP__VariableReserve_ReserveUp)
t = [sum(r[2:end]) for r in eachrow(reg_dn_sim[DateTime("2018-04-01T07:00:00")])]

reg_dn_sim = read_variable(op_problem_res, :REG_DN__VariableReserve_ReserveDown)
t = [sum(r[2:end]) for r in eachrow(reg_dn_sim[DateTime("2018-04-01T07:00:00")])]

using Revise
using PowerSystems
using PowerGraphics
using PowerSimulations
plotlyjs()
results_sim = SimulationResults("results/standard_020/", 1; ignore_status = true)
op_problem_res = get_problem_results(results_sim, "HAUC")
set_system!(op_problem_res, System("data/HA_sys.json"))
p1 = plot_fuel(op_problem_res) #; curtailment = false)

results_sim = SimulationResults("results/standard_july/", 1; ignore_status = true)
op_problem_res = get_problem_results(results_sim, "HAUC")
set_system!(op_problem_res, System("data/HA_sys.json"))
p2 = plot_fuel(op_problem_res; curtailment = false)

build!(DAUC; output_dir = mktempdir(), serialize = false)
solve!(DAUC)
results = ProblemResults(DAUC)

reg = results.variable_values[:REG_UP__VariableReserve_ReserveUp]
traces = Vector{GenericTrace{Dict{Symbol, Any}}}()
for i in eachcol(reg)
    if eltype(i) == Float64 && sum(i) > 1e-3
        push!(traces, scatter(y = i))
    end
end
plot(traces, Layout())
=#
