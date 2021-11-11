function outputdirs = specfem2d_input_setup_flat(name, bottom, depth, water, freq, angle, Par_file_base, outputdir)
% outputdirs = SPECFEM2D_INPUT_SETUP_FLAT(name, bottom, depth, water, freq, angle, Par_file_base, outputdir)
%
% Generates Par_file, source file, and interface file for a fluid-solid
% simulation.
%
% INPUT:
% name              name for the model
% bottom            elevation of ocean floor below mean sea level
% depth             depth of the hydrophone
% water             sound speed profile of the water. Options are the followings:
%                       'homogenous'
%                       'Munk'          Munk sound speed profile
% freq              source frequency [Default: 10 Hz]
% angle             incident angle in degrees [Default: 0]
% Par_file_base     base Par_file to setting up Par_file
% outputdir         directory for the input files
%
% OUTPUT:
% outputdirs        two output directories for the fluid-solid simulation
%       outputdirs{1}       pressure hydrophone in the fluid at depth
%       outputdirs{2}       displacement OBS at the ocean floor
%
% Last modified by sirawich-at-princeton.edu, 11/02/2021

defval('bottom', 4800)
defval('depth', 1500)
defval('water', 'homogeneous')
defval('freq', 10)
defval('angle', 0)

outputdirs = cell(2,1);
% run 2 loops: one for 3-component displacement OBS
%              another for pressure MERMAID
for kk = 1:2
    % load baseline Par_file
    if isempty(Par_file_base)
        params = makeparams();
    else
        params = loadparfile(Par_file_base);
    end

    outputdir_kk = sprintf('%s_%d/', outputdir(1:end-1), kk);
    outputdirs{kk, 1} = outputdir_kk;
    % create the DATA/ folder for the files generated by this function
    system(sprintf('mkdir %s', outputdir_kk));
    system(sprintf('mkdir %sDATA/', outputdir_kk));

    %% define models
    % define material value
    material1 = struct(...
        'model_number'      , 1         , ...
        'type_number'       , 1         , ...
        'type_name'         , 'elastic' , ...
        'rho'               , 2500      , ...
        'vp'                , 3400      , ...
        'vs'                , 1963      , ...
        'QKappa'            , 9999      , ...
        'Qmu'               , 9999        ...
    );

    material2 = struct(...
        'model_number'      , 2         , ...
        'type_number'       , 1         , ...
        'type_name'         , 'acoustic', ...
        'rho'               , 1020      , ...
        'vp'                , 1500      , ...
        'vs'                , 0         , ...
        'QKappa'            , 9999      , ...
        'Qmu'               , 9999        ...
    );

    % set models
    params.nbmodels = 2;
    params.MODELS = {material1, material2};

    %% define geography of the problem

    % set xlimit of the simulation
    xmin = 0;
    xmax = 20000;
    width = xmax - xmin;
    elemsize = 40;
    nx = width / elemsize;

    % set interfaces
    % bottom
    itf1.npts = 2;
    itf1.pts = [xmin 0; xmax 0];
    % ocean bottom
    itf2.npts = 401;
    x = linspace(xmin, xmax, itf2.npts)';
    z = 9600 - bottom * ones(size(x));

    itf2.pts = [x , z];
    % sea surface
    zmax = 9600;
    itf3.npts = 2;
    itf3.pts = [xmin zmax; xmax zmax];

    itfs = {itf1, itf2, itf3};
    % set layers [crust ocean]
    nz = zmax / elemsize;
    layers = [round(nz*z(1)/zmax) nz-round(nz*z(1)/zmax)];

    % write interfaces file
    % set parameters for internal meshing
    params.interfacesfile = sprintf('interfaces_%s.dat', name);
    writeinterfacefile(itfs, layers, sprintf('%sDATA/interfaces_%s.dat', outputdir_kk, name));

    params.read_external_mesh = false;
    params.xmin = xmin;
    params.xmax = xmax;
    params.nx = nx;

    % define regions
    region1 = struct(...
        'nxmin'             , 1         , ...
        'nxmax'             , nx        , ...
        'nzmin'             , 1         , ...
        'nzmax'             , round(nz*z(1)/zmax)      , ...
        'material_number'   , 1           ...
    );

    region2 = struct(...
        'nxmin'             , 1         , ...
        'nxmax'             , nx        , ...
        'nzmin'             , round(nz*z(1)/zmax) + 1  , ...
        'nzmax'             , nz        , ...
        'material_number'   , 2           ...
    );

    regions = {region1, region2};
    params.nbregions = 2;
    params.REGIONS = regions;

    %% define water model
    switch lower(water)
        case 'munk'
            water_model.name = 'Munk';
            water_model.epsilon = 0.00737;
            water_model.zc = 1300;
            water_model.zm = zmax - (min(z) - 500);
            water_model.dz = 10;
            water_model.B = 1300;
        otherwise
            water_model.name = 'homogeneous';
    end

    %% define SOURCE(s)

    % use multiple sources to imitate plane wave
    sources = cell(1, 197);
    for ii = 1:197
        vp = params.MODELS{params.REGIONS{1}.material_number}.vp;
        tshift = (ii - 1) * 100 * sin(angle * pi / 180) / vp;
        source = struct(...
            'source_surf'           , false     , ...   % inside the medium
            'xs'                    , (ii+1) * 100  , ...
            'zs'                    , 720       , ...
            'source_type'           , 2         , ...   % moment tensor
            'time_function_type'    , 1         , ...   % Ricker
            'name_of_source_file'   , '""'      , ...   % blank for now
            'burst_band_width'      , 0         , ...
            'f0'                    , freq      , ...   % dominant frequency
            'tshift'                , tshift    , ...
            'anglesource'           , 0         , ...
            'Mxx'                   , 1.0       , ...   % explosion
            'Mzz'                   , 1.0       , ...   % explosion
            'Mxz'                   , 0.0       , ...   % explosion
            'factor'                , 1e-9 * cos(angle * pi / 180)  ...
        );
        sources{ii} = source;
    end
    % add more sources if angle is 5 degrees or above
    if angle >= 5
        tshift = 0;
        pf = depthprofile(200, itfs, 'linear');
        for ii = 1:50
            zs = 720 + ii * 100;
            layer = sum(pf < zs);
            % stop if the source is above the bottom layer
            % TODO: figure out how to adjust tshift for sources in
            % different materials
            if layer > 1
                break
            end
            vp = params.MODELS{params.REGIONS{layer}.material_number}.vp;
            tshift = tshift + 100 * cos(angle * pi / 180) / vp;
            source = struct(...
                'source_surf'           , false     , ...   % inside the medium
                'xs'                    , 200       , ...
                'zs'                    , zs        , ...
                'source_type'           , 2         , ...   % moment tensor
                'time_function_type'    , 1         , ...   % Ricker
                'name_of_source_file'   , '""'      , ...   % blank for now
                'burst_band_width'      , 0         , ...
                'f0'                    , freq      , ...   % dominant frequency
                'tshift'                , tshift    , ...
                'anglesource'           , 0         , ...
                'Mxx'                   , 1.0       , ...   % explosion
                'Mzz'                   , 1.0       , ...   % explosion
                'Mxz'                   , 0.0       , ...   % explosion
                'factor'                , 1e-9 * sin(angle * pi / 180)  ...
            );
            sources{ii+197} = source;
        end
    end

    params.NSOURCES = length(sources);

    % write source file
    writesource(sources, sprintf('%sDATA/SOURCE_%s', outputdir_kk, name));

    %% defeine set(s) of RECEIVER(s)
    receiverset1 = struct(...
        'nrec'                              , 1     , ...
        'xdeb'                              , 10000 , ...
        'zdeb'                              , zmax - depth  , ...
        'xfin'                              , 10000 , ...
        'zfin'                              , zmax - depth  , ...
        'record_at_surface_same_vertical'   , false   ...
    );
    receiverset2 = struct(...
        'nrec'                              , 1    , ...
        'xdeb'                              , 10000 , ...
        'zdeb'                              , zmax - bottom  , ...
        'xfin'                              , 10000 , ...
        'zfin'                              , zmax - bottom  , ...
        'record_at_surface_same_vertical'   , false   ...
    );

    % hydrophone
    if kk == 1
        params.seismotype = 4;
    % OBS
    else
        params.seismotype = 1;
    end
    receiversets = {receiverset1, receiverset2};
    params.nreceiversets = 2;
    params.RECEIVERS = receiversets;

    % writes STATIONS file to include receiverset information when there are
    % multiple receiversets.
    params = writestations(params, sprintf('%sDATA/STATIONS', outputdir_kk));
    %% define other parameters
    params.title = sprintf('fluid/solid interface : %s', name);
    params.time_stepping_scheme = 1;
    params.NSTEP = 65000;
    params.DT = 5e-4;
    %% write Par_file
    writeparfile(params, sprintf('%sDATA/Par_file_%s', outputdir_kk, name));
    %% write a supplementary file for runthisexample.m
    %  It is not used by specfem2d.
    save(sprintf('%sDATA/supplementary_%s.mat', outputdir_kk, name), 'water_model'); 
end
end